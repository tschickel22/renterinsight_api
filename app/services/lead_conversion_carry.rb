# frozen_string_literal: true

# What moves from a lead to its account at conversion, beyond the activities the
# convert action copies itself: tags, notes and open follow-ups. Scores and AI insights
# stay on the lead, since an account works out its own. Emails and texts are not
# copied: the account's Communication tab reads the converted lead's directly.
class LeadConversionCarry
  OPEN_ACTIVITY = %w[pending in_progress].freeze

  def self.call(lead:, account:, reused_account: false)
    new(lead, account, reused_account).call
  end

  # The lead's copy of a follow-up that now lives on the account stops firing and
  # leaves calendars, so the rep is not told twice.
  def self.retire_open_activity(activity)
    return unless OPEN_ACTIVITY.include?(activity.status)

    activity.update_columns(status: 'cancelled', reminder_sent: true, updated_at: Time.current)
  end

  # One lead activity copied to the account as it was written, and the lead's copy
  # retired if it was still open. The account's entry rules are for new entries; they
  # silently dropped real calls (a lead's call needs no number) and follow-ups.
  def self.copy_activity(la, account:, lead:)
    aa = AccountActivity.new(
      account_id: account.id, user_id: la.user_id, assigned_to_id: la.assigned_to_id,
      activity_type: la.activity_type, subject: la.subject,
      # account_activities.description is NOT NULL and lead_activities allows null.
      description: la.description.presence || la.subject.presence || la.activity_type.to_s.humanize.presence || 'Activity',
      status: la.status, priority: la.priority, due_date: la.due_date, start_time: la.start_time, end_time: la.end_time,
      duration_minutes: la.duration_minutes, completed_at: la.completed_at,
      call_direction: la.call_direction, call_outcome: la.call_outcome,
      phone_number: la.phone_number.presence || lead.phone.presence || (la.activity_type == 'call' ? 'Not recorded' : nil),
      meeting_location: la.meeting_location, meeting_link: la.meeting_link, meeting_attendees: la.meeting_attendees,
      reminder_method: la.reminder_method, reminder_time: la.reminder_time, reminder_sent: la.reminder_sent,
      estimated_hours: la.estimated_hours, actual_hours: la.actual_hours, outcome_notes: la.outcome_notes,
      metadata: la.metadata, created_at: la.created_at, updated_at: la.updated_at
    )
    if aa.save || aa.save(validate: false)
      retire_open_activity(la)
      true
    else
      Rails.logger.warn("[LeadConversionCarry] activity #{la.id} not copied: #{aa.errors.full_messages.join(', ')}")
      false
    end
  end

  def initialize(lead, account, reused_account)
    @lead = lead
    @account = account
    @reused_account = reused_account
  end

  def call
    { tags: carry_tags, notes: carry_notes, follow_ups: carry_reminders + carry_tasks }
  end

  private

  # Written directly so no callbacks run: the account being tagged here is not someone
  # newly tagging it, so no workflow rule starts and no campaign enrolls anyone because
  # a lead converted. Those callbacks run at commit, after any flag set here would be gone.
  def carry_tags
    have = TagAssignment.where(entity_type: 'Account', entity_id: @account.id).pluck(:tag_id)
    now = Time.current
    rows = (@lead.tags.pluck(:id) - have).map do |tag_id|
      { tag_id: tag_id, entity_type: 'Account', entity_id: @account.id, company_id: @lead.company_id,
        assigned_by: 'lead_conversion', assigned_at: now, created_at: now, updated_at: now }
    end
    TagAssignment.insert_all(rows) if rows.any?
    rows.size
  end

  # Notes have been saved under both spellings of the type.
  def carry_notes
    copied = 0
    if @reused_account && @lead.notes.present?
      copied += 1 if Note.new(entity_type: 'account', entity_id: @account.id.to_s, content: @lead.notes,
                              created_by_name: "From lead #{@lead.first_name} #{@lead.last_name}".squish).save
    end
    Note.where(entity_type: %w[lead Lead], entity_id: @lead.id.to_s).order(:created_at).find_each do |note|
      copy = Note.new(entity_type: 'account', entity_id: @account.id.to_s, content: note.content, user_id: note.user_id,
                      created_by_name: note.created_by_name, category: note.category, author_type: note.author_type,
                      created_at: note.created_at, updated_at: note.updated_at)
      copied += 1 if keep(copy)
    end
    copied
  end

  def carry_reminders
    @lead.reminders.where(is_completed: [false, nil]).count do |reminder|
      copied = keep(follow_up('reminder', reminder.title, reminder.description, reminder.due_date, reminder.user_id, reminder.priority))
      reminder.update_columns(is_completed: true, completed_at: Time.current, updated_at: Time.current) if copied
      copied
    end
  end

  def carry_tasks
    @lead.lead_tasks.where(done: [false, nil]).count do |task|
      copied = keep(follow_up('task', task.title, nil, task.due_at, nil, nil))
      task.update_columns(done: true, updated_at: Time.current) if copied
      copied
    end
  end

  def follow_up(type, subject, description, due, user_id, priority)
    AccountActivity.new(account_id: @account.id, activity_type: type, subject: subject, description: description.presence || subject,
                        due_date: due, reminder_time: (type == 'reminder' ? due : nil), reminder_method: (type == 'reminder' ? ['popup'] : nil),
                        status: 'pending', priority: priority.presence || 'medium',
                        user_id: user_id, assigned_to_id: user_id || @lead.owner_id)
  end

  # One record that will not save never stops the conversion; it is logged.
  def keep(record)
    return true if record.save

    Rails.logger.warn("[LeadConversionCarry] lead #{@lead.id}: #{record.class} not copied: #{record.errors.full_messages.join(', ')}")
    false
  end
end
