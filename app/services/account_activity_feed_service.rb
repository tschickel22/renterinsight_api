# frozen_string_literal: true

# Aggregates every activity that belongs to an Account — native
# AccountActivity records plus DealActivity rows on the account's deals
# and ContactActivity rows on the account's contacts.
#
# The account timeline used to only surface native AccountActivity, so
# a call logged on a Contact or a meeting scheduled on a Deal never
# appeared under the parent account. Users had to jump into each child
# entity to see the full history.
#
# Returns a plain Array of hashes with a stable, source-tagged shape so
# the FE can render mixed rows in one list, disable edit/delete on
# rolled-up items, and link to the child entity that owns them.
class AccountActivityFeedService
  # Whitelisted filter params match the AccountActivitiesController#index
  # interface so callers don't need to know the underlying tables.
  def self.feed(account, type: nil, status: nil, assigned_to: nil, limit: 200)
    new(account, type: type, status: status, assigned_to: assigned_to, limit: limit).feed
  end

  def initialize(account, type:, status:, assigned_to:, limit:)
    @account     = account
    @type        = type.presence
    @status      = status.presence
    @assigned_to = assigned_to.presence
    @limit       = limit.to_i.positive? ? limit.to_i : 200
  end

  def feed
    rows = []
    rows.concat(account_rows)
    rows.concat(contact_rows)
    rows.concat(deal_rows)

    # Sort by the most-relevant time: the scheduled slot when present,
    # otherwise creation. Newest first so the timeline reads top-down.
    rows.sort_by! { |r| -(r[:sort_time] || Time.at(0)).to_i }
    rows.first(@limit)
  end

  private

  def account_rows
    scope = @account.activities.includes(:user, :assigned_to)
    scope = scope.where(activity_type: @type) if @type
    scope = scope.where(status: @status)      if @status
    scope = scope.where(assigned_to_id: @assigned_to) if @assigned_to
    scope.map { |a| serialize(a, source: 'account', parent: nil) }
  end

  def contact_rows
    contact_ids = @account.contacts.select(:id) if @account.respond_to?(:contacts)
    return [] if contact_ids.nil?

    scope = ContactActivity.where(contact_id: contact_ids)
                           .includes(:user, :assigned_to, :contact)
    scope = scope.where(activity_type: @type) if @type
    scope = scope.where(status: @status)      if @status
    scope = scope.where(assigned_to_id: @assigned_to) if @assigned_to

    scope.map do |a|
      name = [a.contact&.first_name, a.contact&.last_name].compact.join(' ').presence
      serialize(a, source: 'contact', parent: { type: 'contact', id: a.contact_id, name: name })
    end
  end

  def deal_rows
    deal_ids = @account.deals.select(:id) if @account.respond_to?(:deals)
    return [] if deal_ids.nil?

    scope = DealActivity.where(deal_id: deal_ids)
                        .includes(:user, :assigned_to, :deal)
    scope = scope.where(activity_type: @type) if @type
    scope = scope.where(status: @status)      if @status
    scope = scope.where(assigned_to_id: @assigned_to) if @assigned_to

    scope.map do |a|
      name = a.deal&.name.presence || "Deal ##{a.deal_id}"
      serialize(a, source: 'deal', parent: { type: 'deal', id: a.deal_id, name: name })
    end
  end

  # Emits a JSON-friendly hash that matches the existing controller
  # activity_json shape so the FE reads exactly the same keys whether
  # a row was native or rolled up. Adds `source`, `readOnly`, and
  # `parentEntity` for the rolled-up cases.
  def serialize(activity, source:, parent:)
    sort_time = activity.try(:start_time) || activity.try(:due_date) || activity.created_at

    {
      id:            activity.id,
      source:        source,                     # account | contact | deal
      readOnly:      source != 'account',        # child-owned rows edit at their own detail page
      parentEntity:  parent,                     # { type:, id:, name: } for rolled-up rows
      accountId:     @account.id,
      account:       { id: @account.id, name: @account.name },
      userId:        activity.user_id,
      user:          activity.user ? { id: activity.user.id, name: activity.user.name, email: activity.user.email } : nil,
      assignedToId:  activity.try(:assigned_to_id),
      assignedTo:    activity.try(:assigned_to) ? {
        id:    activity.assigned_to.id,
        name:  activity.assigned_to.name,
        email: activity.assigned_to.email,
      } : nil,
      activityType:  activity.activity_type,
      type:          activity.activity_type,     # legacy alias
      subject:       activity.try(:subject),
      description:   activity.description,
      status:        activity.try(:status),
      priority:      activity.try(:priority),
      dueDate:       activity.try(:due_date)&.iso8601,
      scheduledDate: activity.try(:scheduled_date)&.iso8601,
      startTime:     activity.try(:start_time)&.iso8601,
      endTime:       activity.try(:end_time)&.iso8601,
      durationMinutes: activity.try(:duration_minutes),
      duration:      activity.try(:duration),
      completedAt:   activity.try(:completed_at)&.iso8601,
      callDirection: activity.try(:call_direction),
      callOutcome:   activity.try(:call_outcome),
      phoneNumber:   activity.try(:phone_number),
      meetingLocation: activity.try(:meeting_location),
      meetingLink:   activity.try(:meeting_link),
      meetingAttendees: activity.try(:meeting_attendees),
      outcome:       activity.try(:outcome),
      outcomeNotes:  activity.try(:outcome_notes),
      overdue:       activity.respond_to?(:overdue?) ? activity.overdue? : nil,
      createdAt:     activity.created_at&.iso8601,
      updatedAt:     activity.updated_at&.iso8601,
      sort_time:     sort_time,
    }.compact
  end
end
