# frozen_string_literal: true

module McpPrompts
  class LeadTriage < Base
    prompt_name 'lead_triage'
    title 'Triage new leads'
    description 'Rank the newest leads by how ready they look, with a suggested next step and a first reply for each.'
    arguments [MCP::Prompt::Argument.new(name: 'days', description: 'How many days back to look (default 2)')]

    def self.text_for(args)
      <<~TEXT
        Triage the leads that came in over the last #{days(args, :days, 2)} days.
        Use list_leads with created_after set to that date, then fetch each one (up to 15) to read its notes, timeframe and budget.
        Rank them by how ready to buy they look, and say why in one line each.
        For each, suggest the next step (call, text, email, or book a visit) and draft a short first message.
        #{NO_DASHES}
        Do not change anything. If I ask you to, you can create follow-up tasks or update statuses afterwards.
      TEXT
    end
  end
end
