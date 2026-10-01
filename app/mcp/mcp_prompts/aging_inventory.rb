# frozen_string_literal: true

module McpPrompts
  class AgingInventory < Base
    prompt_name 'aging_inventory'
    title 'Aging inventory'
    description 'Units that have sat longest, with ideas to move them and leads who might fit.'
    arguments [MCP::Prompt::Argument.new(name: 'min_days', description: 'Only units in stock at least this many days (default 90)')]

    def self.text_for(args)
      <<~TEXT
        Show me inventory that has been in stock at least #{days(args, :min_days, 90)} days.
        Use list_inventory with status="available", sort="aging" and that min_days_in_stock.
        For the ten oldest, give the stock number, days in stock and price, and suggest one way to move each one.
        Then use list_leads (sort="recent_activity") and fetch to find open leads whose preferences fit (bedrooms, budget, home type), and suggest who to call about which unit.
        #{NO_DASHES}
      TEXT
    end
  end
end
