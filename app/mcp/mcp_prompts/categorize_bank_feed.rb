# frozen_string_literal: true

module McpPrompts
  class CategorizeBankFeed < Base
    prompt_name 'categorize_bank_feed'
    title 'Categorize my bank feed'
    description 'Work through uncategorized bank transactions in batches, using how you booked the same payee before.'
    arguments [MCP::Prompt::Argument.new(name: 'batch', description: 'Lines per batch (default 20)')]

    def self.text_for(args)
      batch = days(args, :batch, 20).clamp(5, 50)
      <<~TEXT
        Help me categorize my bank feed.
        1. Call list_bank_transactions (status unmatched, limit #{batch}) and tell me how many are waiting and how old the oldest is.
        2. Group this batch by payee_key. For each group show the lines, the suggested_account and its confidence, and anything under looks_like.
        3. Propose an account for each group. Where confidence is low, there is no suggestion, it is a check, or the amount is large or unusual, ask me instead of guessing. Call list_chart_of_accounts if you need the accounts.
        4. Transfers between my own accounts and duplicates should be excluded with exclude_bank_transaction, not booked.
        5. Only after I approve a group, categorize each line with categorize_bank_transaction. Then show what was done and offer the next batch.
        There is a limit on changes per hour; if you reach it, stop and tell me where we left off.
      TEXT
    end
  end
end
