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
                'quantity) and units_this_period for volume bonuses. Warnings name every place the engine pays ' \
                'differently from what the plan says. Uses only the numbers given; never reads real deals.'
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
              units_this_period: { type: 'integer', minimum: 0, description: 'Units the person has delivered in the bonus period' }
            }
          }
        }
      },
      required: %w[scenarios]
    )
    read_only!

    ROLES = %i[primary_salesperson secondary_salesperson sales_manager finance_manager desk_manager].freeze

    # Only the figures the engine reads. Built from what the user typed.
    SimDeal = Struct.new(:commission_plan, :selling_price, :front_gross, :commissionable_front_gross, :back_gross,
                         :total_gross, :addon_gross, keyword_init: true)

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
      engine = CommissionPaymentGeneratorService.new(deal)
      roles = ROLES.filter_map do |role|
        comps = engine.send(:get_components_for_role, role)
        next if comps.empty?

        lines = comps.map { |c| { component: c.name, amount: engine.send(:calculate_component_amount, c).to_f } }
        { role: role.to_s, total: engine.send(:calculate_total_for_components, comps).to_f, components: lines }
      end
      {
        label: input['label'].presence || "Scenario #{index + 1}",
        figures_used: deal.to_h.except(:commission_plan).transform_values { |v| v&.to_f },
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
        addon_gross: num.call('addon_gross') || 0
      )
    rescue ArgumentError
      raise UserError, 'Scenario figures must be numbers.'
    end

    # Where today's engine pays differently from what a component says.
    def self.warnings(components, scenarios)
      out = []
      components.each do |c|
        case c.component_type
        when 'volume_bonus'
          out << "#{c.name}: DealerTide currently pays this bonus (#{c.flat_amount.to_f}) on every closed deal for the " \
                 "role, without checking the #{c.units_threshold} unit #{c.threshold_period} threshold. Until that is " \
                 'fixed, pay volume bonuses by hand or leave them out of the plan.'
        when 'flat_per_unit'
          if scenarios.any? { |s| s['quantity'].to_i > 1 }
            out << "#{c.name}: paid once per deal, not per home, so a multi home deal earns it once."
          end
        when 'addon_commission'
          if c.gross_type.present? && c.gross_type != 'addon'
            out << "#{c.name}: an add-on component pays on its gross type, which is #{c.gross_type}, not add-on gross. " \
                   'Set gross type to Add-on Gross.'
          end
        end
        if (c.deal_type.present? && c.deal_type != 'all') || (c.vertical.present? && c.vertical != 'all')
          out << "#{c.name}: limited to #{[c.deal_type, c.vertical].compact.reject { |v| v == 'all' }.join(' ')} deals, " \
                 'but the payment engine does not apply that limit yet; it pays on every deal type.'
        end
      end
      if components.any? { |c| c.applies_to_role == 'secondary_salesperson' }
        out << 'Components set for the secondary salesperson are not used: a secondary salesperson is paid the ' \
               "primary salesperson's components in full, with no split."
      elsif components.any? { |c| c.applies_to_role.in?([nil, 'primary_salesperson', 'all_participants']) }
        out << 'On a split deal the secondary salesperson is paid the primary components in full as well; there is no split percentage yet.'
      end
      out.uniq
    end
  end
end
