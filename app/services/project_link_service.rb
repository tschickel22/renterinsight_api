# frozen_string_literal: true

# Handing a project, or one phase, to a linked installer company and taking
# it through accept, decline, take back and billing (E68 steps 5c and 5e),
# with its price agreed first: from the installer's rate card, set by the
# dealer, or quoted by the installer and approved by the dealer, plus change
# orders the dealer approves (step 6).
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
  #
  # price_mode: 'card' (card_lines picked from their approved rate card, the
  # total is the fee, approved at hand-off), 'dealer' (the fee the dealer
  # typed) or 'quote' (the installer prices it when accepting, and the dealer
  # approves that before any of it starts). Left out, a fee means 'dealer'
  # and no fee means 'quote'.
  def offer!(project:, link:, phases: [], fee: nil, note: nil, price_mode: nil, card_lines: [])
    raise Error, 'Not your project' unless project.company_id == @company.id
    raise Error, 'Pick an active linked installer' unless link&.active? && link.dealer_company_id == @company.id
    phases = Array(phases).uniq
    raise Error, 'That phase is not on this project' if phases.any? { |ph| ph.project_id != project.id }
    fee = parse_amount(fee)
    price_mode = price_mode.presence || (fee ? 'dealer' : 'quote')
    raise Error, 'Pick how to price it' unless price_mode.in?(ProjectLink::PRICE_SOURCES)

    card = nil
    lines = []
    case price_mode
    when 'card'
      card = link.current_rate_card
      raise Error, "#{link.installer_company.name} has no approved rate card" unless card
      begin
        lines = card.price_lines(card_lines)
      rescue ArgumentError => e
        raise Error, e.message
      end
      raise Error, 'Pick at least one line from their rate card' if lines.empty?
      fee = lines.sum { |l| l['amount'].to_d }
    when 'dealer'
      raise Error, 'Enter the price' unless fee&.positive?
    when 'quote'
      fee = nil
    end

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
                               fee_amount: fee, note: note.presence, offered_by: @actor, offered_at: Time.current,
                               price_source: price_mode, price_lines: lines, link_rate_card: card)
      set_dealer_owner!(pl, link.dealer_vendor_id)
      pl.update!(dealer_cost_item: committed_cost!(pl)) if fee&.positive?
      link.log!('job_offered', "#{@company.name} sent #{pl.scope_label} on #{project.name}", company: @company, user: @actor,
                project_link: pl, data: { fee: fee&.to_s, price_source: price_mode, rate_card_version: card&.version, phase_ids: phases.map(&:id) })
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
      close_installer_copy!(pl)
      pl.company_link.log!('job_cancelled', "#{@company.name} took back #{pl.scope_label}", company: @company, user: @actor, project_link: pl)
    end
    CompanyLinkNotifier.job_cancelled(pl)
    pl
  end

  # ── Installer side ──────────────────────────────────────────────────────

  # price_lines: the installer's price, required on a job sent for a quote.
  # On a priced job it's a different price than the one offered. Either way
  # it waits for the dealer, and the job's phases can't start until then.
  def accept!(pl, price_lines: nil, price_note: nil)
    check_installer!(pl)
    raise Error, 'This job is no longer waiting for you' unless pl.offered?
    lines = Array(price_lines).compact_blank.presence && build_lines(pl, price_lines)
    raise Error, "Enter your price. #{pl.dealer_company.name} asked you to quote this job." if pl.price_source == 'quote' && lines.nil?

    request = nil
    ActiveRecord::Base.transaction do
      pl.lock!
      project = build_installer_project!(pl)
      pl.update!(status: 'accepted', installer_project: project, responded_by: @actor, responded_at: Time.current)
      pl.company_link.log!('job_accepted', "#{@company.name} accepted #{pl.scope_label}", company: @company, user: @actor, project_link: pl)
      request = create_change!(pl, kind: 'price', lines: lines, description: price_note) if lines
    end
    CompanyLinkNotifier.job_answered(pl)
    CompanyLinkNotifier.change_requested(request) if request
    pl
  end

  # ── Price requests and change orders (step 6) ──────────────────────────

  # Installer side. kind 'change' adds work and money; 'price' asks for a
  # different price for the job. dealer_phase_id holds that one phase;
  # without it the request holds every phase of the job not yet started.
  def request_change!(pl, kind:, lines:, description: nil, dealer_phase_id: nil)
    check_installer!(pl)
    raise Error, 'Accept the job first' unless pl.accepted?
    raise Error, 'This job has already been billed' if pl.dealer_bill_id
    raise Error, 'Pick a price request or a change order' unless kind.in?(ProjectLinkChange::KINDS)
    raise Error, 'Describe the change' if kind == 'change' && description.blank?
    raise Error, 'A price request is already waiting for the dealer' if kind == 'price' && pl.link_changes.pending.where(kind: 'price').exists?
    if dealer_phase_id.present?
      phase = pl.dealer_phases.find { |ph| ph.id == dealer_phase_id.to_i }
      raise Error, 'That phase is not on this job' unless phase
      raise Error, "#{phase.name} is already finished" if phase.status.in?(%w[completed skipped])
    end

    change = nil
    ActiveRecord::Base.transaction do
      pl.lock!
      change = create_change!(pl, kind: kind, lines: build_lines(pl, lines), description: description,
                                  dealer_phase_id: phase&.id)
    end
    CompanyLinkNotifier.change_requested(change)
    change
  end

  def withdraw_change!(change)
    pl = change.project_link
    check_installer!(pl)
    raise Error, 'Only a request still waiting can be withdrawn' unless change.pending?

    change.update!(status: 'withdrawn', decided_by: @actor, decided_at: Time.current)
    pl.company_link.log!('change_withdrawn', "#{@company.name} withdrew #{change.label.downcase} on #{pl.scope_label}",
                         company: @company, user: @actor, project_link: pl)
    change
  end

  # Dealer side. An approved price becomes the job's fee and its committed
  # cost; an approved change order adds its own committed cost line.
  def approve_change!(change)
    pl = check_dealer_change!(change)
    ActiveRecord::Base.transaction do
      pl.lock!
      change.update!(status: 'approved', decided_by: @actor, decided_at: Time.current)
      if change.price?
        pl.update!(fee_amount: change.amount, price_lines: change.lines)
        line = pl.dealer_cost_item
        if line && line.status == 'pending' && line.bill_id.nil?
          line.update!(amount: change.amount, unit_price: change.amount)
        else
          pl.update!(dealer_cost_item: committed_cost!(pl))
        end
      else
        change.update!(dealer_cost_item: change_cost!(pl, change))
      end
      pl.installer_project&.update!(budget_amount: pl.approved_total)
      pl.company_link.log!('change_approved', "#{@company.name} approved #{change.label.downcase} on #{pl.scope_label}: " \
                                              "#{money(change.amount)}", company: @company, user: @actor, project_link: pl,
                           data: { change_id: change.id, amount: change.amount.to_s })
    end
    CompanyLinkNotifier.change_decided(change)
    change
  end

  def decline_change!(change, reason: nil)
    pl = check_dealer_change!(change)
    change.update!(status: 'declined', decided_by: @actor, decided_at: Time.current, decline_reason: reason.presence)
    pl.company_link.log!('change_declined', ["#{@company.name} declined #{change.label.downcase} on #{pl.scope_label}", reason.presence].compact.join(': '),
                         company: @company, user: @actor, project_link: pl, data: { change_id: change.id })
    CompanyLinkNotifier.change_decided(change)
    change
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
    if (waiting = pl.link_changes.pending.order(:number).first)
      raise Error, "#{pl.dealer_company.name} hasn't decided on #{waiting.price? ? 'the price' : waiting.label.downcase} yet. Wait for it, or withdraw it."
    end
    amount = parse_amount(amount)
    cost_items = nil
    # A priced job bills what the dealer agreed to, and pays those committed
    # lines, so the job's cost is counted once.
    unless pl.legacy_price?
      raise Error, "#{pl.dealer_company.name} hasn't approved a price for this job yet" unless pl.price_agreed?
      agreed = pl.approved_total
      if amount && amount != agreed
        raise Error, "The approved total is #{money(agreed)}. To bill a different amount, send a change order or a new price first."
      end
      amount = agreed
      cost_items = [pl.dealer_cost_item, *pl.link_changes.approved.where(kind: 'change').order(:number).map(&:dealer_cost_item)].compact
    end
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
                                                     cost_items: cost_items,
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
    pl.link_changes.each do |change|
      change.update!(status: 'withdrawn', decided_at: Time.current) if change.pending?
      next unless (line = change.dealer_cost_item) && line.status == 'pending' && line.bill_id.nil?

      change.update_column(:dealer_cost_item_id, nil)
      line.destroy!
    end
    pl.link_phases.delete_all
  end

  # The installer's copy of a taken-back job leaves its active list. With no
  # costs on it, it's cancelled. With costs (bids awarded, bills in), it goes
  # on hold instead, because a cancelled project drops out of the profit
  # report and those costs are real money the installer still has to settle.
  def close_installer_copy!(pl)
    project = pl.installer_project
    return unless project && project.status.in?(%w[active on_hold])

    has_costs = project.project_cost_items.not_deleted.exists? ||
                pl.installer_company.bills.where(project_id: project.id).where.not(status: 'void').exists?
    project.update!(status: has_costs ? 'on_hold' : 'cancelled')
  end

  def check_dealer_change!(change)
    pl = change.project_link
    raise Error, 'Not your job' unless pl.dealer_company_id == @company.id
    raise Error, 'The link with this installer has ended' unless pl.company_link.active?
    raise Error, 'This request is not waiting for you' unless change.pending?
    raise Error, 'This job is closed' unless pl.accepted?

    pl
  end

  def create_change!(pl, kind:, lines:, description: nil, dealer_phase_id: nil)
    number = (pl.link_changes.maximum(:number) || 0) + 1
    change = pl.link_changes.create!(number: number, kind: kind, lines: lines, description: description.presence,
                                     amount: lines.sum { |l| l['amount'].to_d }, dealer_phase_id: dealer_phase_id,
                                     requested_by: @actor)
    pl.company_link.log!(kind == 'price' ? 'price_requested' : 'change_requested',
                         "#{@company.name} asked for #{kind == 'price' ? 'a price of' : "change order #{number},"} #{money(change.amount)} on #{pl.scope_label}",
                         company: @company, user: @actor, project_link: pl, data: { change_id: change.id, amount: change.amount.to_s })
    change
  end

  # The installer's lines: picked from its approved rate card for this
  # dealer ({ item_key, qty }) or written out ({ name, qty, price }).
  def build_lines(pl, raw)
    card = pl.company_link.current_rate_card
    lines = Array(raw).compact_blank.map do |line|
      line = line.to_h.stringify_keys
      if line['item_key'].present?
        raise Error, 'Your rate card for this dealer is not approved yet' unless card
        begin
          card.price_lines([line]).first
        rescue ArgumentError => e
          raise Error, e.message
        end
      else
        name = line['name'].to_s.strip
        qty = line['qty'].to_s.presence&.to_d || 1.to_d
        price = parse_amount(line['price'])
        raise Error, 'Each line needs a description' if name.blank?
        raise Error, "Enter a quantity for #{name}" unless qty.positive?
        raise Error, "Enter a price for #{name}" unless price && price >= 0

        { 'item_key' => nil, 'name' => name.truncate(200), 'unit' => 'each', 'qty' => qty.to_s,
          'price' => price.to_s, 'amount' => (price * qty).round(2).to_s }
      end
    end
    raise Error, 'Add at least one line' if lines.empty?
    raise Error, 'The total must be more than zero' unless lines.sum { |l| l['amount'].to_d }.positive?

    lines
  end

  def money(amount)
    ActiveSupport::NumberHelper.number_to_currency(amount)
  end

  # An approved change order is committed cost on the dealer's project, on
  # the phase it names (or the job's one phase), until the bill pays it.
  def change_cost!(pl, change)
    pl.dealer_project.project_cost_items.create!(
      company_id: pl.dealer_company_id, project_phase_id: change.dealer_phase_id || pl.dealer_phase&.id,
      vendor_id: pl.company_link.dealer_vendor_id, cost_type: 'subcontractor',
      description: "Installer change order #{change.number}: #{change.description}".truncate(250),
      amount: change.amount, quantity: 1, unit_price: change.amount, date: Date.current, status: 'pending',
      metadata: { 'source' => 'project_link_change', 'project_link_id' => pl.id, 'change_id' => change.id }
    )
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
    if pl.legacy_price?
      invoice.invoice_items.build(description: "#{pl.scope_label}: #{pl.dealer_project.customer_display_name}".truncate(250),
                                  quantity: 1, rate: amount, position: 0)
    else
      # The agreed price, then each approved change order, so both companies'
      # records show the same breakdown.
      invoice.invoice_items.build(description: "#{pl.scope_label}: #{pl.dealer_project.customer_display_name}".truncate(250),
                                  quantity: 1, rate: pl.fee_amount, position: 0)
      pl.link_changes.approved.where(kind: 'change').order(:number).each_with_index do |change, i|
        invoice.invoice_items.build(description: "Change order #{change.number}: #{change.description}".truncate(250),
                                    quantity: 1, rate: change.amount, position: i + 1)
      end
    end
    invoice.save!
    # Finalizing is what posts it to the installer's books (auto-post).
    invoice.update!(status: 'finalized')
    invoice
  end
end
