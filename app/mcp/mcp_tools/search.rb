# frozen_string_literal: true

module McpTools
  # The search half of the search/fetch pair ChatGPT uses for deep research
  # and company knowledge. Results carry typed ids that `fetch` accepts.
  class Search < Base
    tool_name 'search'
    title 'Search'
    description 'Search leads, contacts, accounts, deals, inventory, service tickets and quotes by name, email, ' \
                'phone, stock number, VIN, deal number or ticket number. Returns ids for the fetch tool. Only ' \
                'records the signed-in user can see are searched.'
    input_schema(
      properties: {
        query: { type: 'string', description: 'What to look for, at least 2 characters' },
        types: { type: 'array', items: { type: 'string', enum: Records::TYPES.keys },
                 description: 'Limit to these record types. Default: all the user can read.' }
      },
      required: ['query']
    )
    read_only!

    def self.perform(ctx, query:, types: nil)
      raise UserError, 'Search for at least 2 characters.' if query.to_s.strip.length < 2

      records = Records.new(ctx)
      wanted = records.readable_types
      wanted &= Array(types).map(&:to_s) if types.present?
      budget = ctx.row_limit(30)
      per_type = [[budget / [wanted.size, 1].max, 1].max, 5].min

      results = wanted.flat_map do |type|
        records.search(type, query, per_type).map do |r|
          s = records.summary(type, r)
          { id: s[:id], title: "#{Records::TYPES[type][:label]}: #{s[:title]}", url: s[:url],
            text: s.except(:id, :url, :type, :title).compact.map { |k, v| "#{k}: #{v}" }.join(', ').first(300) }
        end
      end.first(budget)

      Base::Result.new(payload: { results: results }, count: results.size)
    end
  end
end
