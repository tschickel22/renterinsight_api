# frozen_string_literal: true

module McpPrompts
  class BudgetFromLastYear < Base
    prompt_name 'budget_from_last_year'
    title "Draft next year's budget from last year"
    description "Next fiscal year's budget built from last year's actual numbers plus a growth percent, shown before it is saved."
    arguments [
      MCP::Prompt::Argument.new(name: 'growth_percent', description: 'Growth to plan for, e.g. 5 (default 0)'),
      MCP::Prompt::Argument.new(name: 'fiscal_year', description: 'The year to budget (default next fiscal year)')
    ]

    def self.text_for(args)
      growth = (args[:growth_percent] || args['growth_percent']).to_s[/-?\d+(\.\d+)?/] || '0'
      year = (args[:fiscal_year] || args['fiscal_year']).to_s[/\A\d{4}\z/]
      <<~TEXT
        Draft #{year ? "the #{year}" : "next fiscal year's"} budget from last year's actual numbers with #{growth} percent growth.
        1. Call list_budgets to see what already exists, and budget_history for the year before the one we are budgeting.
        2. If budget_history has fewer than 6 months of entries, tell me plainly, and ask whether to annualize what is there or build it from my own numbers instead.
        3. Show me a short summary: revenue, cost of goods sold, expenses and net income for the year, and any account that looks odd.
        4. Only after I say yes, call create_budget_draft with copy_from_fiscal_year and growth_percent #{growth}.
        5. Give me the link and tell me it is a draft that someone has to review and activate in the app.
      TEXT
    end
  end
end
