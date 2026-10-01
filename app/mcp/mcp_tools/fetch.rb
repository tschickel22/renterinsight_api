# frozen_string_literal: true

module McpTools
  # The fetch half of search/fetch: the full record for one typed id.
  class Fetch < Base
    tool_name 'fetch'
    title 'Fetch a record'
    description 'Get the full details of one record by the id that search or a list tool returned, ' \
                'such as lead:42, deal:7 or unit:118. Includes recent notes and activity where there are any.'
    input_schema(
      properties: { id: { type: 'string', description: 'A typed id such as lead:42' } },
      required: ['id']
    )
    read_only!

    def self.perform(ctx, id:)
      ctx.row_limit(1)
      records = Records.new(ctx)
      type, record = records.find(id)
      detail = records.detail(type, record)

      payload = {
        id: detail[:id], title: "#{Records::TYPES[type][:label]}: #{detail[:title]}", url: detail[:url],
        text: JSON.pretty_generate(detail.except(:id, :title, :url)),
        metadata: { type: type }
      }
      # Nested people count too: an account's contact list is records handed out.
      Base::Result.new(payload: payload, count: 1 + Array(detail[:contacts]).size)
    end
  end
end
