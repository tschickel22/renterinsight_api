# frozen_string_literal: true

module McpPrompts
  class MoneySnapshot < Base
    prompt_name 'money_snapshot'
    title 'How is the business doing?'
    description 'Profit, cash, what customers owe and what we owe, in plain words for the owner.'

    def self.text_for(_args)
      <<~TEXT
        Give me a plain-English money snapshot of the business.
        Call accounting_summary. Then tell me, in a few short paragraphs a busy owner can read in a minute:
        how much we made or lost this month and so far this fiscal year, and the biggest costs;
        how much cash is in the bank (book balance);
        what customers owe us and how much of it is late;
        what we owe vendors and what is overdue.
        If many bank transactions are still uncategorized, say up front that the profit numbers are incomplete until they are booked, and how many are waiting.
        If any section was skipped for permissions, say so instead of guessing. No jargon, no tables unless I ask.
      TEXT
    end
  end
end
