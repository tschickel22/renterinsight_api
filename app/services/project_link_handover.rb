# frozen_string_literal: true

# Bids a dealer took on work it then hands to a linked installer. Easy
# Homesource bids a job out before closing so its numbers are exact, then
# turns the job over to AMHI, the installer company it owns, which runs the
# subs and keeps the install on its own books.
#
# At hand-off the dealer picks what goes with the job (handover_mode):
#   contractors  each awarded bid's contractor (matched in the installer's
#                vendor list, or added to it) and amount, awarded there and
#                committed on the installer's phase
#   budget       the bid amounts as each installer phase's budget, no vendors
#   empty        the phases and tasks only, as before
#
# Whichever it is, the work is the installer's now, so the awarded bids come
# off the dealer's project: their committed cost lines are set aside and the
# contractor's unstarted tasks on that work unassigned. Both come back if the
# installer declines or the dealer takes the job back. The dealer's only cost
# for the work is then the installer's fee.
#
# A bid already billed or paid stays with the dealer: that money is real and
# was paid from the dealer's books. Work with open bids, or that an awarded
# contractor has started, can't be sent until that is settled.
class ProjectLinkHandover
  MODES = %w[contractors budget empty].freeze

  class Error < StandardError; end

  # phases: the phases being sent, none for the whole project.
  def initialize(company, project, phases)
    @company = company
    @project = project
    @phases = Array(phases)
  end

  def whole? = @phases.empty?

  # Bid requests on the work being sent.
  def requests
    scope = @company.project_bid_requests.where(project_id: @project.id)
    whole? ? scope : scope.where(project_phase_id: @phases.map(&:id))
  end

  # Awarded bids on the work, each with whether it moves or stays.
  def awarded
    @awarded ||= requests.where(status: 'awarded').includes(:project_phase, awarded_bid: %i[vendor project_cost_item]).filter_map do |req|
      bid = req.awarded_bid
      next unless bid

      cost = bid.project_cost_item
      billed = cost.nil? || cost.is_deleted || cost.bill_id.present? || cost.journal_entry_id.present? || cost.status != 'pending'
      { request: req, bid: bid, cost: cost, billed: billed }
    end
  end

  def moving = awarded.reject { |a| a[:billed] }

  # Reasons the work can't go yet, in the dealer's words.
  def blockers
    out = requests.open.includes(:project_phase).map do |req|
      "#{req.project_phase&.name || req.title} still has open bids. Award one or cancel the request first."
    end
    moving.each do |a|
      next unless started_tasks(a).any?

      out << "#{a[:bid].vendor.name} has started #{a[:request].project_phase&.name || 'the work'}. Finish and bill it here, or leave that phase out."
    end
    out
  end

  # For the Send to installer dialog.
  def preview(installer_company)
    matches = vendor_matcher(installer_company)
    {
      bids: awarded.map do |a|
        bid = a[:bid]
        { bid_id: bid.id, phase_id: a[:request].project_phase_id, phase_name: a[:request].project_phase&.name,
          title: a[:request].title, vendor_name: bid.vendor.name, amount: bid.amount.to_f,
          moves: !a[:billed], at_installer: a[:billed] ? nil : (matches.call(bid.vendor) ? 'existing' : 'new') }
      end,
      moving_total: moving.sum { |a| a[:bid].amount.to_d }.to_f,
      blockers: blockers
    }
  end

  # Dealer side, inside offer!. Records what goes and takes the bids off the
  # dealer's project.
  def hand_off!(pl, mode)
    mode = mode.presence || (moving.any? ? 'contractors' : 'empty')
    raise Error, 'Pick what to send with the job' unless mode.in?(MODES)
    if (problems = blockers).any?
      raise Error, problems.first
    end

    set_aside = { 'cost_item_ids' => [], 'task_assignments' => [] }
    snapshot = moving.map do |a|
      bid = a[:bid]
      req = a[:request]
      a[:cost].update!(is_deleted: true, metadata: (a[:cost].metadata || {}).merge('handed_to_project_link_id' => pl.id))
      set_aside['cost_item_ids'] << a[:cost].id
      bid_tasks(a).each do |task|
        task.contractor_assignments.where(vendor_id: bid.vendor_id).find_each do |asg|
          set_aside['task_assignments'] << asg.attributes.except('id', 'created_at', 'updated_at')
          asg.destroy!
        end
      end
      { 'bid_id' => bid.id, 'request_id' => req.id, 'dealer_phase_id' => req.project_phase_id, 'title' => req.title,
        'scope' => req.scope, 'vendor_id' => bid.vendor_id, 'vendor_name' => bid.vendor.name, 'amount' => bid.amount.to_s,
        'notes' => bid.notes, 'can_start_on' => bid.can_start_on&.iso8601, 'duration_days' => bid.duration_days,
        'submitted_at' => bid.submitted_at&.iso8601 }
    end
    pl.update!(handover_mode: mode, handover_bids: snapshot,
               previous_owners: (pl.previous_owners || {}).merge('handover' => set_aside))
  end

  # Dealer side, when the job comes back (declined or taken back): the bids
  # return to the dealer's project as they were.
  def self.restore!(pl)
    set_aside = (pl.previous_owners || {})['handover']
    return unless set_aside

    ProjectCostItem.where(id: set_aside['cost_item_ids'], company_id: pl.dealer_company_id, is_deleted: true).find_each do |cost|
      cost.update!(is_deleted: false, metadata: (cost.metadata || {}).except('handed_to_project_link_id'))
    end
    Array(set_aside['task_assignments']).each do |attrs|
      next if ContractorAssignment.where(attrs.slice('assignable_type', 'assignable_id', 'vendor_id')).exists?
      next unless Vendor.where(id: attrs['vendor_id'], company_id: pl.dealer_company_id).exists?

      ContractorAssignment.create!(attrs.slice(*ContractorAssignment.column_names))
    end
    pl.update!(previous_owners: pl.previous_owners.except('handover'))
  end

  # Installer side, inside accept! once its copy of the project exists.
  def self.apply!(pl, project, actor:)
    bids = Array(pl.handover_bids)
    return if bids.empty? || pl.handover_mode.in?([nil, 'empty'])

    phase_map = pl.link_phases.includes(:installer_phase).to_h { |lp| [lp.dealer_phase_id, lp.installer_phase] }
    budgets = Hash.new(0.to_d)
    bids.each { |b| budgets[b['dealer_phase_id']] += b['amount'].to_d if b['dealer_phase_id'] }
    budgets.each { |dealer_phase_id, amount| phase_map[dealer_phase_id]&.update!(estimated_budget: amount) }
    return unless pl.handover_mode == 'contractors'

    installer = pl.installer_company
    matcher = new(pl.dealer_company, pl.dealer_project, []).vendor_matcher(installer)
    assignments = []
    bids.each do |b|
      phase = b['dealer_phase_id'] && phase_map[b['dealer_phase_id']]
      next if b['dealer_phase_id'] && phase.nil?

      source = Vendor.find_by(id: b['vendor_id'], company_id: pl.dealer_company_id)
      vendor = (source && matcher.call(source)) || copy_vendor!(installer, source, b, pl)
      amount = b['amount'].to_d
      request = installer.project_bid_requests.create!(
        project: project, project_phase: phase, title: b['title'].presence || 'Bid', scope: b['scope'],
        status: 'awarded', awarded_by: actor, awarded_at: Time.current, created_by: actor
      )
      bid = request.bids.create!(
        company: installer, vendor: vendor, status: 'awarded', amount: amount, notes: b['notes'],
        can_start_on: b['can_start_on'], duration_days: b['duration_days'], entered_by_id: actor&.id,
        invited_at: b['submitted_at'], submitted_at: b['submitted_at'] || Time.current,
        history: [{ 'at' => Time.current.iso8601, 'note' => "Bid of #{money(amount)} carried from #{pl.dealer_company.name}" }]
      )
      cost = project.project_cost_items.create!(
        company: installer, project_phase: phase, vendor_id: vendor.id, vendor_name: vendor.name,
        description: "Bid: #{request.title}".truncate(250), amount: amount, quantity: 1, unit_price: amount,
        cost_type: 'subcontractor',
        status: 'pending', date: Date.current, notes: b['notes'],
        metadata: { 'source' => 'project_link_handover', 'project_link_id' => pl.id, 'dealer_bid_id' => b['bid_id'] }
      )
      bid.update!(project_cost_item_id: cost.id)
      request.update!(awarded_bid_id: bid.id)
      assignments << [phase, vendor]
    end

    # Through the assignment service so the tasks follow and each contractor
    # hears it is now the installer's job, as with an award made there.
    service = ProjectAssignmentService.new(project, actor: actor)
    assignments.each do |phase, vendor|
      phase ? service.assign_phase(phase, { vendor: vendor }, apply_to_tasks: true)
            : service.assign_project({ vendor: vendor }, apply_to_phases: true)
    end
  end

  # The installer's own record of a contractor: same email, or same name.
  def vendor_matcher(installer)
    pool = installer.vendors.active.to_a
    lambda do |source|
      email = source.email.to_s.strip.downcase
      name = source.name.to_s.squish.downcase
      (email.present? && pool.find { |v| v.email.to_s.strip.downcase == email }) ||
        pool.find { |v| v.name.to_s.squish.downcase == name }
    end
  end

  COPIED_VENDOR_FIELDS = %w[name contact_name email phone trade_type vendor_type license_number license_state license_expiry
                            insurance_provider insurance_policy_number insurance_expiry bonded bond_amount bond_expiry
                            hourly_rate website address_line1 address_line2 city state zip_code country tax_id
                            payment_terms is_1099_eligible is_vendor].freeze

  # A contractor the installer doesn't have yet. Text consent was given to
  # the dealer, not the installer, so it doesn't come across; nor do portal
  # sign-ins or account mappings, which belong to each company.
  def self.copy_vendor!(installer, source, snapshot, pl)
    attrs = source ? source.attributes.slice(*COPIED_VENDOR_FIELDS) : { 'name' => snapshot['vendor_name'] }
    installer.vendors.create!(attrs.merge('status' => 'active', 'active' => true,
                                          'notes' => "Added from #{pl.dealer_company.name} with #{pl.dealer_project.customer_display_name.presence || 'a job'} on #{Date.current.strftime('%b %-d, %Y')}"))
  end

  def self.money(amount) = ActiveSupport::NumberHelper.number_to_currency(amount)

  private

  # Tasks on the bid's work: its phase, or every phase being sent for a bid
  # on the whole project.
  def bid_tasks(a)
    phase = a[:request].project_phase
    phases = phase ? [phase] : (whole? ? @project.project_phases.to_a : @phases)
    ProjectPhaseTask.where(project_phase_id: phases.map(&:id)).includes(:contractor_assignments).to_a
  end

  def started_tasks(a)
    vendor_id = a[:bid].vendor_id
    bid_tasks(a).select do |task|
      mine = task.contractor_assignments.select { |asg| asg.vendor_id == vendor_id }
      mine.any? && (task.status == 'completed' ||
        mine.any? { |asg| asg.status.in?(ProjectAssignmentService::STARTED_ASSIGNMENT_STATUSES) || asg.review_status.present? })
    end
  end
end
