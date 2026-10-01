# frozen_string_literal: true

module McpTools
  # Same save path as the app's lead edit, so the new owner gets the usual
  # "lead assigned" notification.
  class AssignLead < Base
    tool_name 'assign_lead'
    title 'Assign a lead'
    description 'Make another user (id from get_reference_data) the owner of a lead. They are notified as ' \
                'they would be if the lead were reassigned in the app.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'lead:42' },
        user_id: { type: 'integer' }
      },
      required: %w[id user_id]
    )
    writes!

    def self.perform(ctx, id:, user_id:)
      records = Records.new(ctx)
      type, lead = records.find(id)
      raise UserError, 'That id is not a lead.' unless type == 'lead'

      ctx.authorize!('leads', 'update')
      owner = WriteHelpers.assignable_user!(ctx, user_id)
      lead.update!(owner_id: owner.id)

      Base::Result.new(payload: { updated: records.summary('lead', lead) }, count: 1)
    end
  end
end
