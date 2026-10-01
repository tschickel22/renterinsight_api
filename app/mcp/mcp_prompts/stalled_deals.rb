# frozen_string_literal: true

module McpPrompts
  class StalledDeals < Base
    prompt_name 'stalled_deals'
    title 'Stalled deals'
    description 'Open deals nobody has moved lately, with what to do next on each.'
    arguments [MCP::Prompt::Argument.new(name: 'days', description: 'Not updated in this many days (default 14)')]

    def self.text_for(args)
      <<~TEXT
        Find open deals that have not been updated in #{days(args, :days, 14)} days, using list_deals with that stale_days.
        Group them by stage. Fetch the ones worth the most to read their notes and stage history.
        For each, say what seems to be holding it up and the single next step, and who should take it.
        Do not move any deal. If I agree, you can add notes or tasks afterwards.
      TEXT
    end
  end
end
