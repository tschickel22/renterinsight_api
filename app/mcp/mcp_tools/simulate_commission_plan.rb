# frozen_string_literal: true

module McpTools
  # What a plan would pay on deals the user describes, worked out by the same
  # code that makes real payments (CommissionPaymentGeneratorService), so a
  # simulation cannot promise what the engine will not pay. Where the engine
  # pays differently from what a component says, the result says so plainly.
  #
  # Never touches a real deal. An inline plan (components not yet saved) is
  # built inside a transaction that is always rolled back.
  class SimulateCommissionPlan < Base
    tool_name 'simulate_commission_plan'
    title 'Test a commission plan on example deals'
    description 'Work out what a commission plan pays on example deals the user describes, exactly as DealerTide ' \
                'would pay it today, per role and per component. Give plan_id for a saved plan, or components ' \
                '(same shape as create_commission_plan_draft) to test a design before saving. Each scenario takes ' \
                'the deal figures (front_gross, back_gross, addon_gross, pack, and optionally ' \
                'commissionable_front_gross, total_gross, selling_price, deal_type new or used, vertical mh or rv, ' \
                'quantity, split_with_secondary) and units_this_period for volume bonuses: the unit this deal is for the ' \
                'person in the bonus period, counting this one (a volume bonus pays once, on the unit that reaches its ' \
                'threshold). Warnings name anything the plan will not do the way it reads. Uses only the numbers given; ' \
                'never reads real deals.'
    input_schema(
      properties: {
        plan_id: { type: 'string', description: 'commission_plan:4' },
        components: CommissionPlanSupport::COMPONENT_SCHEMA,
        scenarios: {
          type: 'array', minItems: 1, maxItems: 10,
          items: {
            type: 'object',
            properties: {
              label: { type: 'string' },
              selling_price: { type: 'number' },
              front_gross: { type: 'number', description: 'Accounting front gross, before pack' },
              pack: { type: 'number', description: 'Dealer pack taken off front gross before commission' },
              commissionable_front_gross: { type: 'number', description: 'Defaults to front_gross minus pack' },
              back_gross: { type: 'number', description: 'Finance reserve plus product margin' },
              total_gross: { type: 'number', description: 'Defaults to front_gross plus back_gross' },
              addon_gross: { type: 'number', description: 'Delivery, setup, skirting, accessories' },
              deal_type: { type: 'string', enum: %w[new used] },
              vertical: { type: 'string', enum: %w[mh rv] },
              quantity: { type: 'integer', minimum: 1 },
              split_with_secondary: { type: 'boolean', description: 'A second salesperson shares the deal (50/50 split)' },
              units_this_period: { type: 'integer', minimum: 1, description: 'Which unit this is for the person in the bonus period, counting this deal' }
            }
          }
        }
      },
      required: %w[scenarios]
    )
    read_only!

    ROLES = %i[primary_salesperson secondary_salesperson sales_manager finance_manager desk_manager].freeze

    # Only what the engine reads, built from what the user typed. A
    # secondary salesperson id stands in for "someone shares this deal".
    SimDeal = Struct.new(:commission_plan, :selling_price, :front_gross, :commissionable_front_gross, :back_gross,
                         :total_gross, :addon_gross, :quantity, :commission_deal_type, :commission_vertical,
                         :primary_salesperson_id, :secondary_salesperson_id, keyword_init: true)

    def self.perform(ctx, scenarios:, plan_id: nil, components: nil)
      CommissionPlanSupport.require!(ctx, 'read')
      raise UserError, 'Give plan_id or components, not both.' if plan_id.present? && components.present?
      raise UserError, 'Give plan_id for a saved plan, or components to test a design.' if plan_id.blank? && components.blank?

      list = Array(scenarios).map { |s| s.to_h.deep_stringify_keys }
      raise UserError, 'Give between 1 and 10 scenarios.' unless (1..10).cover?(list.size)

      payload =
        if plan_id.present?
          run(CommissionPlanSupport.find_plan(ctx, plan_id), list)
        else
          inline(ctx, components, list)
        end
      Base::Result.new(payload: payload, count: 0)
    end

    def self.inline(ctx, components, list)
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        plan = ctx.company.commission_plans.new(name: 'Simulation', is_active: false, is_default: false)
        built, notes = CommissionPlanSupport.build_components(ctx, plan, components)
        CommissionPlanSupport.validate!(plan, built)
        plan.save!
        built.each(&:save!)
        result = run(plan, list, label: 'unsaved design').merge(rate_notes: notes.presence).compact
        raise ActiveRecord::Rollback
      end
      result
    end

    def self.run(plan, list, label: "commission_plan:#{plan.id}")
      plan_components = plan.commission_components.where(is_active: true).ordered.to_a
      {
        plan: label,
        scenarios: list.each_with_index.map { |s, i| scenario(plan, s, i) },
        warnings: warnings(plan_components, list),
        note: 'Amounts are what DealerTide would pay today for a closed won deal with these figures. A role is ' \
              'paid only when that person is on the deal.'
      }
    end

    def self.scenario(plan, input, index)
      deal = sim_deal(plan, input)
      position = input['units_this_period'].presence&.to_i || 1
      engine = CommissionPaymentGeneratorService.new(deal, volume_position: position)
      roles = ROLES.filter_map do |role|
        lines = engine.lines_for_role(role)
        next if lines.empty?

        { role: role.to_s, total: engine.total_for_role(role).to_f,
          components: lines.map { |l| { component: l[:component].name, amount: l[:amount].to_f, note: l[:note] }.compact } }
      end
      {
        label: input['label'].presence || "Scenario #{index + 1}",
        figures_used: deal.to_h.slice(:selling_price, :front_gross, :commissionable_front_gross, :back_gross, :total_gross,
                                      :addon_gross).transform_values { |v| v&.to_f }
                          .merge(quantity: deal.quantity, deal_type: deal.commission_deal_type,
                                 vertical: deal.commission_vertical, split_with_secondary: deal.secondary_salesperson_id.present?,
                                 units_this_period: position).compact,
        payouts: roles
      }
    end

    # Defaults mirror Deal: commissionable front = front minus pack, total =
    # front plus back.
    def self.sim_deal(plan, s)
      num = ->(key) { s[key].nil? ? nil : BigDecimal(s[key].to_s) }
      front = num.call('front_gross')
      back = num.call('back_gross') || 0
      SimDeal.new(
        commission_plan: plan, selling_price: num.call('selling_price'), front_gross: front,
        commissionable_front_gross: num.call('commissionable_front_gross') || (front && (front - (num.call('pack') || 0))),
        back_gross: back, total_gross: num.call('total_gross') || ((front || 0) + back),
        addon_gross: num.call('addon_gross') || 0,
        quantity: [s['quantity'].to_i, 1].max, commission_deal_type: s['deal_type'].presence,
        commission_vertical: s['vertical'].presence, primary_salesperson_id: 1,
        secondary_salesperson_id: s['split_with_secondary'] ? 2 : nil
      )
    rescue ArgumentError
      raise UserError, 'Scenario figures must be numbers.'
    end

    # Where the plan will not do what it reads like it does.
    def self.warnings(components, scenarios)
      out = []
      components.each do |c|
        limited = [c.deal_type, c.vertical].compact_blank.reject { |v| v == 'all' }
        if limited.any?
          out << "#{c.name}: limited to #{limited.join(' ')} deals. A real deal counts as new or used only when its " \
                 'deal type or its home says so; a deal with neither gets nothing from this component.'
        end
        if c.component_type == 'volume_bonus' && scenarios.none? { |s| s['units_this_period'].to_i == c.units_threshold.to_i }
          out << "#{c.name}: pays once per #{c.threshold_period == 'quarterly' ? 'quarter' : 'month'}, on unit " \
                 "#{c.units_threshold}. None of these scenarios is that unit, so it shows 0; add one with " \
                 "units_this_period #{c.units_threshold} to see it."
        end
      end
      out.uniq
    end
  end
end
