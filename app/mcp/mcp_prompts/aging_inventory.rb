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
        If that returns nothing, call list_inventory with status="available" and no min_days_in_stock before saying nothing is aging: when those units have no days_in_stock, their in-stock dates were never entered, so tell me how many are missing it and that aging cannot be judged until the in-stock date is filled in on each unit in the app. Do not call an empty list good news.
        For the ten oldest, give the stock number, days in stock and price, and suggest one way to move each one.
        Then use list_leads (sort="recent_activity") and fetch to find open leads whose preferences fit (bedrooms, budget, home type), and suggest who to call about which unit.
        #{NO_DASHES}
      TEXT
    end
  end
end
