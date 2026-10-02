# frozen_string_literal: true

module McpPrompts
  class LeadsSlipping < Base
    prompt_name 'leads_slipping'
    title 'Leads slipping through the cracks'
    description 'Open leads with no next step scheduled, who owns them, and the ones worth a call this week.'
    arguments [MCP::Prompt::Argument.new(name: 'days', description: 'Quiet for at least this many days (default 14)')]

    def self.text_for(args)
      quiet = days(args, :days, 14)
      <<~TEXT
        Call lead_follow_up_gaps with quiet_days=#{quiet} and tell me in a few lines how many open leads have no next step, and who owns the most of them.
        Then call list_leads with no_follow_up=true, quiet_days=#{quiet} and sort="stale", and pick the ten most worth a call, latest stages first. Fetch any you need to read the notes.
        For each, one line: who, what they wanted, the last touch, and the next step you suggest.
        Do not change anything. If I agree, you can schedule follow-ups with add_lead_follow_up.
      TEXT
    end
  end
end
