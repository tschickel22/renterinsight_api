# frozen_string_literal: true

module McpPrompts
  class BillsDue < Base
    prompt_name 'bills_due'
    title 'Bills due'
    description 'Vendor bills that are overdue or due soon, against the cash in the bank.'
    arguments [MCP::Prompt::Argument.new(name: 'days', description: 'Due within this many days (default 14)')]

    def self.text_for(args)
      days = days(args, :days, 14)
      <<~TEXT
        Show me the bills I need to pay.
        1. Call list_bills with overdue_only=true, then with due_within_days=#{days}.
        2. Call accounting_summary for book cash per bank account and how many bank lines are still uncategorized.
        3. List overdue bills first (vendor, amount, days late), then the ones due in the next #{days} days, with a running total.
        4. Compare the total due with cash on hand. If cash looks short, say which bills could wait based on how late they already are, and say plainly that book cash is only as current as the categorized bank feed.
        Do not pay or change anything. Include each bill's link.
      TEXT
    end
  end
end
