# frozen_string_literal: true

module McpPrompts
  class CompareCommissionPlans < Base
    prompt_name 'compare_commission_plans'
    title 'Compare two commission plans'
    description 'What changes for a salesperson moving from one plan to another, on the deals you typically do.'
    arguments [
      MCP::Prompt::Argument.new(name: 'from_plan', description: 'Current plan name'),
      MCP::Prompt::Argument.new(name: 'to_plan', description: 'New plan name')
    ]

    def self.text_for(args)
      from = (args[:from_plan] || args['from_plan']).to_s.strip.first(100)
      to = (args[:to_plan] || args['to_plan']).to_s.strip.first(100)
      <<~TEXT
        Call list_commission_plans and find #{from.present? ? "\"#{from}\"" : 'the current plan'} and #{to.present? ? "\"#{to}\"" : 'the new plan'} (ask me if it is unclear which).
        Agree with me on three to five typical deals for this dealership: a low gross deal, an average one, a strong one with finance and add-ons, and a used home if we sell them. Ask for the figures rather than guessing.
        Run simulate_commission_plan on the same scenarios for each plan and show one table: scenario, role, pay under the old plan, pay under the new plan, difference.
        Summarize in three sentences who comes out ahead, on which kinds of deals, and roughly what it means over a month of typical volume.
        List any simulation warnings for either plan. Do not change either plan. #{NO_DASHES}
      TEXT
    end
  end
end
