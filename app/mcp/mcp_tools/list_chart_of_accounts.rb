# frozen_string_literal: true

module McpTools
  class ListChartOfAccounts < ListTool
    tool_name 'list_chart_of_accounts'
    title 'List GL accounts'
    description 'Active GL accounts that can be posted to (no header accounts), by account number. Filter by type ' \
                '(asset, liability, equity, revenue, expense), sub_type, or a name/number search. Use the ids ' \
                '(gl_account:45) with categorize_bank_transaction.'
    input_schema(
      properties: {
        type: { type: 'string', enum: ChartOfAccount::TYPES },
        sub_type: { type: 'string' },
        query: { type: 'string', description: 'Name or number contains' },
        limit: { type: 'integer', minimum: 1, maximum: 200, description: 'Default 200' }
      }
    )

    def self.perform(ctx, type: nil, sub_type: nil, query: nil, limit: 200)
      AccountingAccess.require!(ctx, 'chart_of_accounts', 'read')
      rel = ctx.company.chart_of_accounts.postable.ordered
      rel = rel.where(account_type: type) if type.present?
      rel = rel.where(sub_type: sub_type) if sub_type.present?
      if query.present?
        term = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
        rel = rel.where('chart_of_accounts.name ILIKE :t OR chart_of_accounts.account_number ILIKE :t', t: term)
      end
      # A chart of accounts is reference data, not customer records: a full
      # chart (100 or so) fits one call and counts once against the budget.
      rows = rel.limit([[limit.to_i, 1].max, 200].min).to_a
      ctx.row_limit(1)
      items = rows.map { |a| AccountingAccess.gl_account(a).merge(description: a.description.presence).compact }
      Base::Result.new(payload: { count: items.size, items: items, url: ctx.app_url('/accounting/chart-of-accounts') }, count: 1)
    end
  end
end
