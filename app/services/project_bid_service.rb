# frozen_string_literal: true

# Bids on a phase or a whole project (E68 step 4).
#
# The dealer sends a request to several contractors; each answers in the
# portal (or staff type in a phone bid). Awarding one assigns the work through
# ProjectAssignmentService, so unstarted tasks follow as in E69, and adds a
# pending Subcontractor cost line for the bid amount. That cost line is the
# committed cost the job cost reports count, and the contractor's portal
# invoice bills against it.
class ProjectBidService
  class Error < StandardError; end

  def initialize(company, actor: nil)
    @company = company
    @actor = actor
  end

  # Returns the request. vendor_ids must be active contractors of this company.
  def send_request!(project:, phase: nil, title: nil, scope: nil, bids_due_on: nil, start_wanted_on: nil, vendor_ids: [])
    vendors = contractors_for(vendor_ids)
    raise Error, 'Pick at least one contractor to ask' if vendors.empty?
    if phase && @company.project_bid_requests.open.where(project_phase_id: phase.id).exists?
      raise Error, "#{phase.name} already has open bids. Add contractors to that request instead."
    end

    request = nil
    ActiveRecord::Base.transaction do
      request = @company.project_bid_requests.create!(
        project: project, project_phase: phase,
        # Not the project name: it often carries the customer's name, and bidders see the title.
        title: title.presence || (phase ? phase.name : 'The whole job'),
        scope: scope.presence || default_scope_for(project, phase),
        bids_due_on: bids_due_on, start_wanted_on: start_wanted_on,
        created_by_id: @actor&.id
      )
      vendors.each { |v| invite!(request, v) }
    end
    request.bids.each { |bid| ProjectBidNoticeJob.perform_later(bid.id, 'requested') }
    request
  end

  # Adds contractors to an open request. Returns the new bids.
  def invite_more!(request, vendor_ids)
    raise Error, 'This request is closed' unless request.open?

    taken = request.bids.pluck(:vendor_id)
    vendors = contractors_for(vendor_ids).reject { |v| taken.include?(v.id) }
    raise Error, 'Those contractors are already on this request' if vendors.empty?

    bids = ActiveRecord::Base.transaction { vendors.map { |v| invite!(request, v) } }
    bids.each { |bid| ProjectBidNoticeJob.perform_later(bid.id, 'requested') }
    bids
  end

  # A bid from the portal, or typed in by staff (entered_by). Staff changing a
  # bid the contractor sent themselves must give a reason: it is kept on the
  # bid and sent to the contractor, so nobody's price changes behind their back.
  def submit!(bid, amount:, can_start_on: nil, duration_days: nil, notes: nil, entered_by: nil, reason: nil)
    request = bid.project_bid_request
    raise Error, 'Bidding on this request is closed' unless request.open?

    value = BigDecimal(amount.to_s) rescue nil
    raise Error, 'Enter the bid amount' unless value&.positive?

    days = duration_days.presence && Integer(duration_days.to_s, exception: false)
    raise Error, 'Days must be a whole number' if duration_days.present? && !days&.positive?

    start = can_start_on.presence && (Date.parse(can_start_on.to_s) rescue nil)
    raise Error, 'Pick a valid start date' if can_start_on.present? && start.nil?

    first_answer = !bid.status.in?(%w[submitted])
    change = entered_by && contractors_own_answer?(bid) && staff_change(bid, value.round(2), start, days, notes.presence)
    if change
      raise Error, "#{bid.vendor.name} sent this bid themselves. Say why you're changing it; they'll be told." if reason.blank?

      change = change.merge('at' => Time.current.iso8601, 'by_id' => entered_by.id,
                            'by_name' => entered_by.full_name.presence || entered_by.email, 'reason' => reason.to_s.strip)
    end
    attrs = { status: 'submitted', amount: value.round(2), can_start_on: start, duration_days: days,
              notes: notes.presence, submitted_at: Time.current }
    # A correction keeps the bid the contractor's own; a phone bid is the staff member's.
    attrs[:entered_by_id] = entered_by&.id unless change
    attrs[:history] = bid.history + [change] if change
    bid.update!(attrs)
    if entered_by
      ProjectNotificationService.refresh_bid_review_item(request)
      ProjectBidNoticeJob.perform_later(bid.id, 'changed_by_dealer') if change
    else
      ProjectNotificationService.announce_bid_submitted(bid, revised: !first_answer)
    end
    bid
  end

  MAX_FILE_SIZE = 25.megabytes

  # A file the contractor sends with their bid: a quote sheet, photos, a spec.
  def attach_file!(bid, file)
    request = bid.project_bid_request
    raise Error, 'Bidding on this request is closed' unless request.open?
    raise Error, 'Choose a file' if file.blank? || !file.respond_to?(:original_filename)
    raise Error, 'Files can be up to 25 MB' if file.size > MAX_FILE_SIZE

    stored = PrivateFiles.upload(file, folder: "projects/#{@company.id}/#{request.project_id}/bids")
    request.project.project_documents.create!(
      company_id: @company.id, title: "Bid from #{bid.vendor.name}: #{file.original_filename}".truncate(250),
      category: 'bid', documentable: request.project_phase,
      file_url: stored[:ref], file_s3_key: stored[:key], file_name: file.original_filename,
      file_size: stored[:size], content_type: stored[:content_type],
      metadata: { 'project_bid_id' => bid.id, 'uploaded_by_contractor_id' => bid.vendor_id }
    )
  end

  def remove_file!(bid, document_id)
    raise Error, 'Bidding on this request is closed' unless bid.project_bid_request.open?

    doc = bid.documents.find_by(id: document_id)
    raise Error, 'File not found' unless doc

    doc.update!(is_deleted: true)
  end

  def decline!(bid, notes: nil)
    raise Error, 'Bidding on this request is closed' unless bid.project_bid_request.open?

    bid.update!(status: 'declined', amount: nil, notes: notes.presence, submitted_at: Time.current)
    ProjectNotificationService.announce_bid_submitted(bid, revised: false)
    bid
  end

  def award!(request, bid, notify_others: true, note: nil)
    raise Error, 'This request is closed' unless request.open?
    raise Error, 'That bid is not on this request' unless bid.project_bid_request_id == request.id
    raise Error, 'Only a bid with an amount can be awarded' unless bid.status == 'submitted' && bid.amount.to_d.positive?

    vendor = @company.contractors.active.find_by(id: bid.vendor_id)
    raise Error, "#{bid.vendor.name} is no longer an active contractor" unless vendor

    project = request.project
    phase = request.project_phase
    losers = []
    ActiveRecord::Base.transaction do
      request.lock!
      raise Error, 'This request is closed' unless request.open?

      cost = project.project_cost_items.create!(
        company: @company, project_phase: phase, vendor_id: vendor.id, vendor_name: vendor.name,
        description: "Bid: #{request.title}", amount: bid.amount, cost_type: 'subcontractor',
        status: 'pending', date: Date.current, notes: bid.notes
      )
      bid.update!(status: 'awarded', project_cost_item_id: cost.id)
      losers = request.bids.where(status: 'submitted').where.not(id: bid.id).to_a
      request.bids.where(id: losers.map(&:id)).update_all(status: 'not_awarded', updated_at: Time.current)
      request.update!(status: 'awarded', awarded_bid_id: bid.id, awarded_by_id: @actor&.id, awarded_at: Time.current,
                      award_note: note.presence,
                      previous_vendor_id: phase ? phase.assigned_vendor_id : project.assigned_vendor_id)

      assign!(project, phase, vendor)
    end

    ProjectNotices.close!(subject: request, kinds: 'bid_received', resolution: 'awarded', by: @actor)
    # The winner hears it was them, with the dealer's note, by email and text.
    ProjectBidNoticeJob.perform_later(bid.id, 'awarded')
    if notify_others
      losers.each { |b| ProjectBidNoticeJob.perform_later(b.id, 'awarded_elsewhere') }
    end
    bid
  end

  # Takes an award back while its cost line has not been billed and the
  # contractor has not started.
  def undo_award!(request)
    raise Error, 'This request has no award to undo' unless request.awarded?

    bid = request.awarded_bid
    cost = bid&.project_cost_item
    if cost && (cost.bill_id.present? || cost.journal_entry_id.present? || cost.status != 'pending')
      raise Error, 'The awarded cost is already billed or paid, so the award stays'
    end

    project = request.project
    phase = request.project_phase
    previous = request.previous_vendor_id && @company.contractors.active.find_by(id: request.previous_vendor_id)
    current_owner = phase ? phase.assigned_vendor_id : project.assigned_vendor_id
    service = ProjectAssignmentService.new(project, actor: @actor)
    if current_owner == bid&.vendor_id
      check = phase ? service.assign_phase(phase, { vendor: previous }, apply_to_tasks: true, preview: true)
                    : service.assign_project({ vendor: previous }, apply_to_phases: true, preview: true)
      raise Error, "#{bid.vendor.name} has started work, so the award stays" if check.tasks_started.positive?

      # The preview rolled back the database, not these objects.
      phase&.reload
      project.reload
    end

    ActiveRecord::Base.transaction do
      request.lock!
      cost&.destroy!
      request.bids.where(status: %w[awarded not_awarded]).update_all(status: 'submitted', project_cost_item_id: nil, updated_at: Time.current)
      request.update!(status: 'open', awarded_bid_id: nil, awarded_by_id: nil, awarded_at: nil, previous_vendor_id: nil,
                      award_note: nil)
      # Only move the work back if nobody has reassigned it since.
      assign!(project, phase, previous) if current_owner == bid&.vendor_id
    end
    ProjectNotificationService.refresh_bid_review_item(request)
    request
  end

  def cancel!(request, notify: true)
    raise Error, 'Only an open request can be cancelled' unless request.open?

    request.update!(status: 'cancelled', cancelled_at: Time.current)
    ProjectNotices.close!(subject: request, kinds: 'bid_received', resolution: 'cancelled', by: @actor)
    if notify
      request.bids.where(status: %w[invited submitted]).each { |bid| ProjectBidNoticeJob.perform_later(bid.id, 'closed') }
    end
    request
  end

  private

  # The contractor answered it themselves (portal), as opposed to a phone bid
  # staff typed in.
  def contractors_own_answer?(bid)
    bid.status.in?(%w[submitted declined]) && bid.entered_by_id.nil? && bid.submitted_at.present?
  end

  # What staff are changing, or nil when nothing is.
  def staff_change(bid, amount, start, days, notes)
    from = { 'amount' => bid.amount&.to_s, 'can_start_on' => bid.can_start_on&.iso8601,
             'duration_days' => bid.duration_days, 'notes' => bid.notes, 'status' => bid.status }
    to = { 'amount' => amount.to_s, 'can_start_on' => start&.iso8601, 'duration_days' => days,
           'notes' => notes, 'status' => 'submitted' }
    changed = to.keys.select { |k| from[k].to_s != to[k].to_s }
    changed.reject! { |k| k == 'amount' && from[k].present? && from[k].to_d == to[k].to_d }
    return nil if changed.empty?

    { 'from' => from.slice(*changed), 'to' => to.slice(*changed) }
  end

  def contractors_for(ids)
    ids = Array(ids).map(&:to_i).uniq.reject(&:zero?)
    return [] if ids.empty?

    @company.contractors.active.where(id: ids).to_a
  end

  def invite!(request, vendor)
    request.bids.create!(company: @company, vendor: vendor, status: 'invited', invited_at: Time.current)
  end

  def assign!(project, phase, vendor)
    service = ProjectAssignmentService.new(project, actor: @actor)
    if phase
      service.assign_phase(phase, { vendor: vendor }, apply_to_tasks: true)
    else
      service.assign_project({ vendor: vendor }, apply_to_phases: true)
    end
  end

  def default_scope_for(project, phase)
    phases = phase ? [phase] : project.project_phases.where.not(status: %w[completed skipped]).to_a
    phases.map do |p|
      tasks = p.project_phase_tasks.map { |t| "- #{t.name}" }
      ([p.name] + tasks).join("\n")
    end.join("\n\n")
  end
end
