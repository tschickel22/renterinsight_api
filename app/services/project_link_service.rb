# frozen_string_literal: true

# Handing a project, or one phase, to a linked installer company and taking
# it through accept, decline, take back and billing (E68 steps 5c and 5e).
#
# Every write to the other company's records happens here or in
# ProjectLinkSync, with both companies named and the link checked. Nothing a
# request sends picks a company.
class ProjectLinkService
  class Error < StandardError; end

  def initialize(company, actor:)
    @company = company
    @actor = actor
  end

  # ── Dealer side ─────────────────────────────────────────────────────────

  # phases: none for the whole project, or one or more of its phases for one
  # fee (install and delivery together, say).
  def offer!(project:, link:, phases: [], fee: nil, note: nil)
    raise Error, 'Not your project' unless project.company_id == @company.id
    raise Error, 'Pick an active linked installer' unless link&.active? && link.dealer_company_id == @company.id
    phases = Array(phases).uniq
    raise Error, 'That phase is not on this project' if phases.any? { |ph| ph.project_id != project.id }
    fee = parse_amount(fee)

    live = ProjectLink.live.where(dealer_project_id: project.id).to_a
    taken = live.flat_map { |l| l.dealer_phases.map(&:id) }
    if live.any?(&:whole_project?) || (phases.empty? && live.any?) || (phases.map(&:id) & taken).any?
      raise Error, 'This work is already with an installer'
    end

    pl = nil
    ActiveRecord::Base.transaction do
      pl = ProjectLink.create!(company_link: link, dealer_company: @company, installer_company: link.installer_company,
                               dealer_project: project, dealer_phase: phases.one? ? phases.first : nil,
                               dealer_phase_ids: phases.many? ? phases.sort_by(&:position).map(&:id) : [],
                               fee_amount: fee, note: note.presence, offered_by: @actor, offered_at: Time.current)
      set_dealer_owner!(pl, link.dealer_vendor_id)
      pl.update!(dealer_cost_item: committed_cost!(pl)) if fee&.positive?
      link.log!('job_offered', "#{@company.name} sent #{pl.scope_label} on #{project.name}", company: @company, user: @actor,
                project_link: pl, data: { fee: fee&.to_s, phase_ids: phases.map(&:id) })
    end
    CompanyLinkNotifier.job_offered(pl)
    pl
  end

  # Take a job back: before it's accepted, or after if the installer hasn't
  # billed it. The installer keeps its copy, marked as taken back.
  def cancel!(pl)
    raise Error, 'Not your job' unless pl.dealer_company_id == @company.id
    raise Error, 'This job is already closed' unless pl.status.in?(%w[offered accepted])
    raise Error, 'The installer has already billed this job' if pl.dealer_bill_id || pl.installer_invoice_id

    ActiveRecord::Base.transaction do
      pl.update!(status: 'cancelled')
      release_dealer!(pl)
      pl.company_link.log!('job_cancelled', "#{@company.name} took back #{pl.scope_label}", company: @company, user: @actor, project_link: pl)
    end
    CompanyLinkNotifier.job_cancelled(pl)
    pl
  end

  # ── Installer side ──────────────────────────────────────────────────────

  def accept!(pl)
    check_installer!(pl)
    raise Error, 'This job is no longer waiting for you' unless pl.offered?

    ActiveRecord::Base.transaction do
      pl.lock!
      project = build_installer_project!(pl)
      pl.update!(status: 'accepted', installer_project: project, responded_by: @actor, responded_at: Time.current)
      pl.company_link.log!('job_accepted', "#{@company.name} accepted #{pl.scope_label}", company: @company, user: @actor, project_link: pl)
    end
    CompanyLinkNotifier.job_answered(pl)
    pl
  end

  def decline!(pl, reason: nil)
    check_installer!(pl)
    raise Error, 'This job is no longer waiting for you' unless pl.offered?

    ActiveRecord::Base.transaction do
      pl.update!(status: 'declined', decline_reason: reason.presence, responded_by: @actor, responded_at: Time.current)
      release_dealer!(pl)
      pl.company_link.log!('job_declined', ["#{@company.name} declined #{pl.scope_label}", reason.presence].compact.join(': '),
                           company: @company, user: @actor, project_link: pl)
    end
    CompanyLinkNotifier.job_answered(pl)
    pl
  end

  # The installer bills the dealer for the job: an invoice in the installer's
  # books (to the dealer's customer account) and a draft bill in the dealer's,
  # against the committed cost line, on the deal's project.
  def bill_dealer!(pl, amount:, invoice_number: nil, notes: nil)
    check_installer!(pl)
    raise Error, 'Accept the job before billing it' unless pl.status.in?(%w[accepted done])
    raise Error, 'This job has already been billed' if pl.dealer_bill_id
    amount = parse_amount(amount)
    raise Error, 'Enter the amount' unless amount&.positive?

    link = pl.company_link
    invoice = nil
    bill = nil
    ActiveRecord::Base.transaction do
      pl.lock!
      invoice = installer_invoice!(pl, amount, notes)
      dealer_project = pl.dealer_project
      bill = ContractorInvoiceService.new(contractor: link.dealer_vendor, project: dealer_project, phase: pl.dealer_phase)
                                     .submit_linked!(amount: amount, invoice_number: invoice_number.presence || invoice.invoice_number,
                                                     notes: notes, due_date: invoice.due_date, source: 'linked_installer',
                                                     submission: { 'project_link_id' => pl.id, 'installer_company' => @company.name })
      pl.update!(installer_invoice: invoice, dealer_bill: bill)
      link.log!('job_billed', "#{@company.name} billed #{ActiveSupport::NumberHelper.number_to_currency(amount)} for #{pl.scope_label}",
                company: @company, user: @actor, project_link: pl, data: { amount: amount.to_s, invoice_id: invoice.id, bill_id: bill.id })
    end
    # Into the installer's books now rather than trusting the invoice's own
    # after_commit, which a second save in the same transaction can skip.
    # Posting checks the company's setting and never posts twice.
    Accounting::InvoicePostingService.new(invoice).post!
    CompanyLinkNotifier.job_billed(pl)
    pl
  end

  private

  def check_installer!(pl)
    raise Error, 'Not your job' unless pl.installer_company_id == @company.id
    raise Error, 'The link with this dealer has ended' unless pl.company_link.active?
  end

  def parse_amount(value)
    return nil if value.blank?

    value.to_s.delete(',$').to_d
  end

  # The dealer's phases (or project) show the installer as their owner. Set
  # straight on the columns: the assignment service would hand each task to
  # the installer as a portal contractor, and the installer is a company.
  # Whoever owned them before is kept, so a take back or decline restores them.
  def set_dealer_owner!(pl, vendor_id)
    project = pl.dealer_project
    phases = pl.whole_project? ? project.project_phases.where.not(status: %w[completed skipped]).to_a : pl.dealer_phases
    previous = { 'phases' => phases.to_h { |ph| [ph.id.to_s, ph.assigned_vendor_id] } }
    previous['project'] = project.assigned_vendor_id if pl.whole_project?
    pl.update!(previous_owners: previous)

    project.update!(assigned_vendor_id: vendor_id) if pl.whole_project?
    ProjectPhase.where(id: phases.map(&:id)).update_all(assigned_vendor_id: vendor_id, updated_at: Time.current)
  end

  # Gives the work back to whoever had it, unless someone has changed the
  # owner since.
  def release_dealer!(pl)
    vendor_id = pl.company_link.dealer_vendor_id
    previous = pl.previous_owners || {}
    pl.dealer_phases.each do |ph|
      ph.update!(assigned_vendor_id: previous.dig('phases', ph.id.to_s)) if ph.assigned_vendor_id == vendor_id
    end
    if pl.whole_project? && pl.dealer_project.assigned_vendor_id == vendor_id
      pl.dealer_project.update!(assigned_vendor_id: previous['project'])
    end
    if (line = pl.dealer_cost_item) && line.status == 'pending' && line.bill_id.nil?
      pl.update_column(:dealer_cost_item_id, nil)
      line.destroy!
    end
    pl.link_phases.delete_all
  end

  # The installer's fee is the dealer's committed cost, like an awarded bid.
  def committed_cost!(pl)
    pl.dealer_project.project_cost_items.create!(
      company_id: @company.id, project_phase_id: pl.dealer_phase&.id, vendor_id: pl.company_link.dealer_vendor_id,
      cost_type: 'subcontractor', description: "Installer: #{pl.scope_label}", amount: pl.fee_amount, quantity: 1,
      unit_price: pl.fee_amount, date: Date.current, status: 'pending',
      metadata: { 'source' => 'project_link', 'project_link_id' => pl.id }
    )
  end

  # The installer's copy: customer and site, the handed-off phases with their
  # tasks and dates. It never notifies the customer; the dealer's project does.
  def build_installer_project!(pl)
    dp = pl.dealer_project
    location_id = @company.locations.where(is_deleted: [false, nil]).order(:id).pick(:id)
    project = @company.projects.create!(
      name: [dp.customer_display_name.presence, (pl.scope_label unless pl.whole_project?)].compact.join(' - ').presence || dp.name,
      description: [pl.note, dp.description].compact_blank.join("\n\n").presence,
      status: 'active', location_id: location_id, owner_id: @actor.id, created_by_id: @actor.id,
      customer_name: dp.customer_name, customer_email: dp.customer_email, customer_phone: dp.customer_phone,
      delivery_street: dp.delivery_street, delivery_city: dp.delivery_city, delivery_state: dp.delivery_state, delivery_zip: dp.delivery_zip,
      home_make: dp.home_make, home_model: dp.home_model, home_serial_number: dp.home_serial_number,
      budget_amount: pl.fee_amount, client_visible: false
    )
    pl.dealer_phases.each_with_index do |dph, i|
      iph = project.project_phases.create!(
        company_id: @company.id, name: dph.name, description: dph.description, position: i, status: copy_status(dph.status),
        started_at: dph.started_at, completed_at: dph.completed_at,
        estimated_start_date: dph.estimated_start_date, estimated_completion_date: dph.estimated_completion_date,
        estimated_days: dph.estimated_days, notes: dph.client_notes.presence, is_required: dph.is_required,
        visible_to_client: false, notify_client_on_start: false, notify_client_on_complete: false
      )
      dph.project_phase_tasks.order(:position).each do |t|
        iph.project_phase_tasks.create!(company_id: @company.id, name: t.name, position: t.position, is_required: t.is_required,
                                        status: t.status == 'completed' ? 'completed' : 'pending', completed_at: t.completed_at,
                                        estimated_days: t.estimated_days, estimated_start_date: t.estimated_start_date,
                                        estimated_completion_date: t.estimated_completion_date, visible_to_client: false)
      end
      pl.link_phases.create!(dealer_phase: dph, installer_phase: iph)
    end
    project.update_progress_cache!
    project
  end

  def copy_status(status)
    status.in?(ProjectPhase::STATUSES) ? status : 'not_started'
  end

  def installer_invoice!(pl, amount, notes)
    account = pl.company_link.installer_dealer_account
    location_id = pl.installer_project&.location_id || @company.locations.order(:id).pick(:id)
    invoice = @company.invoices.new(
      location_id: location_id, recipient: account, source: pl.installer_project, billing_category: 'customer',
      invoice_date: Date.current, due_date: Date.current + 30, status: 'draft',
      notes: ["#{pl.scope_label} for #{pl.dealer_project.customer_display_name}", notes.presence].compact.join("\n")
    )
    invoice.invoice_items.build(description: "#{pl.scope_label}: #{pl.dealer_project.customer_display_name}".truncate(250),
                                quantity: 1, rate: amount, position: 0)
    invoice.save!
    # Finalizing is what posts it to the installer's books (auto-post).
    invoice.update!(status: 'finalized')
    invoice
  end
end
