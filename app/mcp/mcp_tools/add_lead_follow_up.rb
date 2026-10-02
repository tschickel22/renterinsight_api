# frozen_string_literal: true

module McpTools
  # Puts a next step on a lead the way a rep does on the lead page: a lead
  # activity (task, call or reminder) with a due time, assigned to the lead's
  # owner unless someone else is named. It shows on the lead and in that
  # person's My Tasks, and reminds them when it comes due.
  class AddLeadFollowUp < Base
    tool_name 'add_lead_follow_up'
    title 'Add a lead follow-up'
    description "Schedule the next step on a lead: a task, a call to make or a reminder, due at a date in the " \
                "dealer's local time, assigned to the lead's owner (or the signed-in user when it has none) " \
                'unless assigned_to_user_id is given. The assignee gets the usual reminder when it is due. ' \
                "Local time means the time zone of the lead's location, else the signed-in user's location, " \
                "else the company's setting. The reply names the zone it used (time_zone) and gives the due " \
                'time with its offset. Tell the person which zone was used, and pass on any time_zone_warning.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'lead:42' },
        subject: { type: 'string', description: 'What to do, e.g. "Call about the 3 bed Clayton"' },
        due_date: { type: 'string', description: "ISO date or date-time in the dealer's local time, e.g. 2026-10-06 or 2026-10-06T10:00" },
        kind: { type: 'string', enum: %w[task call reminder], description: 'Default task' },
        priority: { type: 'string', enum: %w[low medium high urgent] },
        assigned_to_user_id: { type: 'integer' },
        description: { type: 'string' }
      },
      required: %w[id subject due_date]
    )
    writes!(destructive: false)

    def self.perform(ctx, id:, subject:, due_date:, kind: 'task', priority: 'medium', assigned_to_user_id: nil,
                     description: nil)
      type, lead = Records.new(ctx).find(id)
      raise UserError, 'That id is not a lead.' unless type == 'lead'

      ctx.authorize!('crm', 'create')
      raise UserError, 'The subject is empty.' if subject.to_s.strip.empty?

      assignee_id =
        if assigned_to_user_id.present? then WriteHelpers.assignable_user!(ctx, assigned_to_user_id).id
        elsif lead.owner_id && ctx.company.users.active.exists?(id: lead.owner_id) then lead.owner_id
        else ctx.user.id
        end
      due, zone = LocalTime.parse!(ctx, due_date, location_id: lead.location_id)
      kind = kind.presence || 'task'

      activity = lead.lead_activities.new(
        activity_type: kind, subject: subject.to_s.strip.first(255), description: description,
        status: 'pending', priority: priority.presence || 'medium', due_date: due,
        user_id: ctx.user.id, assigned_to_id: assignee_id
      )
      activity.call_direction = 'outbound' if kind == 'call'
      activity.reminder_time = due if kind == 'reminder'
      activity.save!
      ctx.record_change(action: 'created', record: activity, after: { status: activity.status })

      Base::Result.new(payload: { scheduled: {
        id: "lead:#{lead.id}", kind: kind, subject: activity.subject, due: LocalTime.iso(activity.due_date, zone),
        due_utc: activity.due_date.utc.iso8601, **zone.describe,
        assigned_to: ctx.user_names[assignee_id], url: Records.new(ctx).url('lead', lead)
      } }, count: 1)
    end
  end
end
