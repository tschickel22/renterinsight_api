# frozen_string_literal: true

module McpTools
  # Adds a real note to the record's notes timeline (the Notes tab), signed by
  # the user. Never touches the record's legacy notes field, which the app's
  # own "notes" endpoint overwrites.
  class AddNote < Base
    tool_name 'add_note'
    title 'Add a note'
    description 'Add a note to a lead, contact, account, deal, inventory unit, service ticket or quote, by the ' \
                'id from search or a list tool. It appears on the record signed by the user.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'Typed id such as lead:42' },
        text: { type: 'string', description: 'The note' }
      },
      required: %w[id text]
    )
    writes!

    def self.perform(ctx, id:, text:)
      raise UserError, 'The note is empty.' if text.to_s.strip.empty?

      records = Records.new(ctx)
      type, record = records.find(id)
      ctx.authorize!(WriteHelpers.entity_resource(type), 'update')

      note = Note.create!(
        entity_type: WriteHelpers.note_entity_type(type), entity_id: record.id.to_s,
        content: text.to_s.strip.first(10_000), user_id: ctx.user.id, created_by_name: ctx.user.full_name
      )
      ctx.record_change(action: 'created', record: note, after: { content: note.content })
      Base::Result.new(payload: { added: { note_id: note.id, on: "#{type}:#{record.id}", url: records.url(type, record) } }, count: 1)
    end
  end
end
