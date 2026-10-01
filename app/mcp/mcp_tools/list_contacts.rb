# frozen_string_literal: true

module McpTools
  class ListContacts < ListTool
    tool_name 'list_contacts'
    title 'List contacts'
    description 'List customer contacts, most recently updated first, optionally matching a name, email or phone.'
    input_schema(
      properties: {
        query: { type: 'string', description: 'Name, email or phone contains' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, query: nil, limit: 20)
      records = Records.new(ctx)
      rel = records.scope('contact')
      rel = rel.where(id: records.search('contact', query, 500).map(&:id)) if query.present?
      listing(ctx, 'contact', rel.order(updated_at: :desc), limit)
    end
  end
end
