# frozen_string_literal: true

module McpTools
  class GetBudget < Base
    tool_name 'get_budget'
    title 'Read a budget'
    description 'One budget in full: every line by account with its 12 months in fiscal order (month_labels ' \
                'names them), grouped into revenue, cost of goods sold and expenses with subtotals and net income. ' \
                'editable_here is true only for drafts, the only budgets this connector can change.'
    input_schema(
      properties: { id: { type: 'string', description: 'budget:12' } },
      required: ['id']
    )
    read_only!

    def self.perform(ctx, id:)
      BudgetArea.require!(ctx, 'read')
      ctx.row_limit(1)
      budget = BudgetArea.find!(ctx, id)
      Base::Result.new(payload: BudgetArea.detail(ctx, budget), count: 1)
    end
  end
end
