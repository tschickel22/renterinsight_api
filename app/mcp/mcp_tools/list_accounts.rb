# frozen_string_literal: true

module McpTools
  class ListAccounts < ListTool
    tool_name 'list_accounts'
    title 'List accounts'
    description 'List accounts (households or businesses), most recently updated first, optionally by status ' \
                'or matching a name, email, phone or account number.'
    input_schema(
      properties: {
        query: { type: 'string' },
        status: { type: 'string', enum: Account::STATUSES },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, query: nil, status: nil, limit: 20)
      records = Records.new(ctx)
      rel = records.scope('account')
      rel = rel.where(id: records.search('account', query, 500).map(&:id)) if query.present?
      rel = rel.where(status: status) if status.present?
      listing(ctx, 'account', rel.order(updated_at: :desc), limit)
    end
  end
end
