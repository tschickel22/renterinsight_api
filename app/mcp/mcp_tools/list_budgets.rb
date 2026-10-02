# frozen_string_literal: true

module McpTools
  class ListBudgets < Base
    tool_name 'list_budgets'
    title 'List budgets'
    description 'List the budgets this person can see, newest fiscal year first, with status (draft, active, ' \
                'locked, archived), location and total budgeted. Filter by fiscal_year, status or location_id.'
    input_schema(
      properties: {
        fiscal_year: { type: 'integer' },
        status: { type: 'string', enum: Budget::STATUSES },
        location_id: { type: 'integer', description: 'From get_reference_data' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )
    read_only!

    def self.perform(ctx, fiscal_year: nil, status: nil, location_id: nil, limit: 20)
      BudgetArea.require!(ctx, 'read')
      rel = BudgetArea.scope(ctx)
      rel = rel.where(fiscal_year: fiscal_year.to_i) if fiscal_year.present?
      rel = rel.where(status: status) if status.present?
      rel = rel.where(location_id: location_id.to_i) if location_id.present?
      budgets = rel.includes(:location).order(fiscal_year: :desc, created_at: :desc).limit(ctx.row_limit(limit)).to_a

      items = budgets.map { |b| BudgetArea.summary(ctx, b) }
      Base::Result.new(payload: { count: items.size, current_fiscal_year: BudgetArea.current_fiscal_year(ctx.company),
                                  items: items }, count: items.size)
    end
  end
end
