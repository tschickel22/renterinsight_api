# frozen_string_literal: true

module McpTools
  class UpdateLeadStatus < Base
    tool_name 'update_lead_status'
    title 'Change a lead status'
    description "Change a lead's status to one of the company's status keys (see get_reference_data). " \
                'Optionally leave a note saying why.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'lead:42' },
        status: { type: 'string' },
        note: { type: 'string' }
      },
      required: %w[id status]
    )
    writes!(destructive: true)

    def self.perform(ctx, id:, status:, note: nil)
      records = Records.new(ctx)
      type, lead = records.find(id)
      raise UserError, 'That id is not a lead.' unless type == 'lead'

      ctx.authorize!('leads', 'update')
      key = WriteHelpers.lead_status!(ctx, status)
      from = lead.status
      lead.update!(status: key)
      ctx.record_change(action: 'updated', record: lead, before: { status: from }, after: { status: key })
      if note.present?
        created = Note.create!(entity_type: 'lead', entity_id: lead.id.to_s, content: note.to_s.strip.first(10_000),
                               user_id: ctx.user.id, created_by_name: ctx.user.full_name)
        ctx.record_change(action: 'created', record: created, after: { content: created.content })
      end

      Base::Result.new(payload: { updated: records.summary('lead', lead), from: from, to: key }, count: 1)
    end
  end
end
