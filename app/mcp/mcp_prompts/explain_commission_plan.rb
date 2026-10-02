# frozen_string_literal: true

module McpPrompts
  class ExplainCommissionPlan < Base
    prompt_name 'explain_commission_plan'
    title 'Explain a commission plan'
    description 'A commission plan in plain words, with two worked examples a salesperson would recognize.'
    arguments [MCP::Prompt::Argument.new(name: 'plan', description: 'Plan name (leave blank to pick from a list)')]

    def self.text_for(args)
      name = (args[:plan] || args['plan']).to_s.strip.first(100)
      <<~TEXT
        Call list_commission_plans and find #{name.present? ? "the plan called \"#{name}\"" : 'the plans, then ask me which one'}; read it with get_commission_plan.
        Explain in plain words who it applies to, when it applies, and what each component pays, as I would explain it to a new salesperson.
        Then run simulate_commission_plan on two typical deals for this dealership (ask me for a typical front gross, pack, back gross and add-ons if you do not know) and show what each person on the deal would be paid in a small table.
        If the simulation returns warnings, tell me each one plainly; they are places where the app pays differently from what the plan says.
        Do not change the plan. #{NO_DASHES}
      TEXT
    end
  end
end
