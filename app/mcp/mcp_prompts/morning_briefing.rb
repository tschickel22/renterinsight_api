# frozen_string_literal: true

module McpPrompts
  class MorningBriefing < Base
    prompt_name 'morning_briefing'
    title 'My morning briefing'
    description 'What needs you today: overdue and due tasks, new leads, leads going cold, deals that stalled.'

    def self.text_for(_args)
      <<~TEXT
        Give me my morning briefing.
        1. Call list_my_tasks with overdue_only=true, then again with due_within_days=0, and list what is overdue and what is due today.
        2. Call list_leads with owner="me" and sort="newest" and tell me which came in since yesterday.
        3. Call list_leads with owner="me" and sort="stale" and name the five I have not touched the longest.
        4. Call list_deals with salesperson="me" and stale_days=7 for open deals that have gone quiet.
        Finish with the three things I should do first and why. Keep it short. Include each record's link.
      TEXT
    end
  end
end
