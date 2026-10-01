# frozen_string_literal: true

module McpTools
  # The signed-in user's own open to-dos: tasks plus lead follow-ups (calls,
  # meetings, reminders) assigned to them, soonest due first. A user's own
  # work needs no extra permission, matching the app's My Tasks.
  class ListMyTasks < ListTool
    tool_name 'list_my_tasks'
    title 'My open tasks'
    description "The signed-in user's open tasks and lead follow-ups (calls, meetings, reminders), soonest due " \
                'first. overdue_only=true lists only what is past due.'
    input_schema(
      properties: {
        overdue_only: { type: 'boolean' },
        due_within_days: { type: 'integer', minimum: 0 },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, overdue_only: false, due_within_days: nil, limit: 30)
      cap = ctx.row_limit(limit)
      cutoff = overdue_only ? Time.current : (due_within_days.present? ? due_within_days.to_i.days.from_now.end_of_day : nil)

      tasks = ctx.company.tasks.active.where(assigned_to_id: ctx.user.id)
      tasks = tasks.where('tasks.due_date <= ?', cutoff) if cutoff
      task_items = tasks.order(Arel.sql('tasks.due_date ASC NULLS LAST')).limit(cap).map do |t|
        {
          id: "task:#{t.id}", kind: 'task', title: t.title, status: t.status, priority: t.priority,
          due: t.due_date&.iso8601, overdue: t.due_date.present? && t.due_date < Time.current,
          related: t.taskable_type && t.taskable_id ? "#{t.taskable_type} #{t.taskable_id}" : nil
        }.compact
      end

      activities = LeadActivity.joins(:lead).where(leads: { company_id: ctx.company.id })
                               .where(assigned_to_id: ctx.user.id, status: %w[pending in_progress])
                               .where.not(activity_type: 'note')
      activities = activities.where('lead_activities.due_date <= ?', cutoff) if cutoff
      activity_items = activities.order(Arel.sql('lead_activities.due_date ASC NULLS LAST')).limit(cap)
                                 .includes(:lead).map do |a|
        {
          id: "lead:#{a.lead_id}", kind: a.activity_type, title: a.subject, status: a.status, priority: a.priority,
          due: a.due_date&.iso8601, overdue: a.due_date.present? && a.due_date < Time.current,
          related: "Lead #{[a.lead&.first_name, a.lead&.last_name].compact_blank.join(' ')}"
        }.compact
      end

      items = (task_items + activity_items).sort_by { |i| i[:due] || '9999' }.first(cap)
      Base::Result.new(payload: { count: items.size, items: items }, count: items.size)
    end
  end
end
