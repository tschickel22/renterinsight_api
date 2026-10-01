# frozen_string_literal: true

module McpTools
  class CreateTask < Base
    tool_name 'create_task'
    title 'Create a task'
    description 'Create a task, optionally linked to a lead, contact, account, deal or service ticket, ' \
                'assigned to the signed-in user unless another user id is given.'
    input_schema(
      properties: {
        title: { type: 'string' },
        due_date: { type: 'string', description: "ISO date or date-time in the dealer's local time, e.g. 2026-10-02 (end of that day) or 2026-10-02T15:00" },
        priority: { type: 'string', enum: %w[low medium high urgent] },
        related_id: { type: 'string', description: 'Typed id such as lead:42' },
        assigned_to_user_id: { type: 'integer' },
        description: { type: 'string' }
      },
      required: %w[title]
    )
    writes!(destructive: false)

    TASKABLE = { 'lead' => 'Lead', 'contact' => 'Contact', 'account' => 'Account', 'deal' => 'Deal',
                 'ticket' => 'ServiceTicket' }.freeze

    def self.perform(ctx, title:, due_date: nil, priority: 'medium', related_id: nil, assigned_to_user_id: nil,
                     description: nil)
      ctx.authorize!('tasks', 'create')

      task = ctx.company.tasks.new(
        title: title.to_s.strip.first(255), description: description, priority: priority.presence || 'medium',
        status: 'pending', created_by: ctx.user.full_name, source_type: 'ai_connector',
        assigned_to_id: assigned_to_user_id.present? ? WriteHelpers.assignable_user!(ctx, assigned_to_user_id).id : ctx.user.id
      )
      if related_id.present?
        type, record = Records.new(ctx).find(related_id)
        raise UserError, "Tasks can be linked to #{TASKABLE.keys.join(', ')}." unless TASKABLE.key?(type)

        task.taskable_type = TASKABLE[type]
        task.taskable_id = record.id
        task.location_id = record.try(:location_id)
      end
      task.location_id ||= ctx.default_location_id
      task.due_date = WriteHelpers.parse_due!(ctx, due_date, location_id: task.location_id) if due_date.present?
      task.save!
      ctx.record_change(action: 'created', record: task, after: { status: task.status })

      Base::Result.new(payload: { created: { id: "task:#{task.id}", title: task.title, due: task.due_date&.iso8601,
                                             assigned_to: ctx.user_names[task.assigned_to_id] } }, count: 1)
    end
  end
end
