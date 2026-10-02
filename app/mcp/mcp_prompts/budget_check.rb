# frozen_string_literal: true

module McpPrompts
  class BudgetCheck < Base
    prompt_name 'budget_check'
    title 'How are we doing against budget'
    description 'This month and the year to date against budget, the biggest misses in plain words, and what to look at.'

    def self.text_for(_args)
      <<~TEXT
        Tell me how the business is doing against budget.
        1. Call budget_variance with period "ytd" (it picks the active budget for this fiscal year; if it asks which one, ask me).
        2. Call budget_variance again with period "month" for last month (a month like 2026-09).
        3. Say in two or three sentences whether we are ahead or behind on net income, year to date and last month.
        4. List the three biggest misses with the dollar amount and a likely reason in plain words, then the biggest win.
        If no_actuals_posted is true, say the books have nothing posted for that period yet instead of calling it a miss.
        Do not change anything. Keep it short and include the budget link.
      TEXT
    end
  end
end
