# frozen_string_literal: true

module McpTools
  # Shared by the commission plan tools: plan and permission checks, the
  # component input shape, and how a plan is described.
  #
  # The line the connector holds: plan DESIGN (rates and structure) is open to
  # people who can read commission plans in the app. What a named person
  # earned (commissions, commission payments) never comes through here, and
  # simulations run on deals the user describes, never on real deals' gross.
  #
  # Plans built here are always saved inactive. A deal picks up only an
  # active, current plan (Deal#determine_commission_plan), so a draft pays
  # nobody until an admin activates it in DealerTide.
  module CommissionPlanSupport
    MODULE_KEY = 'management.commissions'

    COMPONENT_FIELDS = %w[name description component_type gross_type rate flat_amount units_threshold
                          threshold_period applies_to_role deal_type vertical].freeze

    COMPONENT_SCHEMA = {
      type: 'array',
      description: 'The pieces of the plan, paid in order. component_type: percent_of_gross (needs gross_type and rate), ' \
                   'flat_per_unit (flat_amount per deal), volume_bonus (flat_amount, units_threshold, threshold_period ' \
                   'monthly or quarterly), addon_commission (rate on add-on gross: delivery, setup, skirting, accessories). ' \
                   "gross_type: #{CommissionComponent::GROSS_TYPES.join(', ')} (commissionable_front is front gross minus pack, " \
                   'what most dealers pay on). rate is a percent: 25 or 0.25 both mean 25%. applies_to_role: ' \
                   "#{CommissionComponent::ROLES.join(', ')}. deal_type: #{CommissionComponent::DEAL_TYPES.join(', ')}. " \
                   "vertical: #{CommissionComponent::VERTICALS.join(', ')}.",
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          description: { type: 'string' },
          component_type: { type: 'string', enum: CommissionComponent::COMPONENT_TYPES },
          gross_type: { type: 'string', enum: CommissionComponent::GROSS_TYPES },
          rate: { type: 'number', description: 'Percent: 25 or 0.25 both mean 25%' },
          flat_amount: { type: 'number' },
          units_threshold: { type: 'integer' },
          threshold_period: { type: 'string', enum: CommissionComponent::THRESHOLD_PERIODS },
          applies_to_role: { type: 'string', enum: CommissionComponent::ROLES },
          deal_type: { type: 'string', enum: CommissionComponent::DEAL_TYPES },
          vertical: { type: 'string', enum: CommissionComponent::VERTICALS }
        },
        required: %w[name component_type applies_to_role]
      }
    }.freeze

    PLAN_FIELDS = %w[name description assigned_user_id assigned_role effective_date expiration_date location_id].freeze

    module_function

    def require!(ctx, action, components: nil)
      unless ModuleAccessService.new(ctx.company).has_module?(MODULE_KEY)
        raise Denied, "The Commission Engine is not part of this account's plan, so I cannot read or build commission plans."
      end

      ctx.authorize!('commission_plans', action)
      ctx.authorize!('commission_components', components) if components
    end

    def find_plan(ctx, id)
      raw = id.to_s.delete_prefix('commission_plan:')
      raise UserError, "Plan ids look like commission_plan:4, not #{id.inspect}." unless raw.match?(/\A\d+\z/)

      plan = ctx.scope_locations(ctx.company.commission_plans, include_unlocated: true).find_by(id: raw.to_i)
      raise ActiveRecord::RecordNotFound unless plan

      plan
    end

    def plan_url(ctx, plan)
      ctx.app_url("/commissions/plans/#{plan.id}")
    end

    def status(plan)
      return 'inactive' unless plan.is_active
      return 'expired' if plan.expiration_date && plan.expiration_date < Date.current
      return 'future' if plan.effective_date && plan.effective_date > Date.current

      'current'
    end

    def assignment(ctx, plan)
      if plan.assigned_user_id
        { kind: 'user', user: ctx.user_names[plan.assigned_user_id] || "user #{plan.assigned_user_id}" }
      elsif plan.assigned_role.present?
        { kind: 'role', role: plan.assigned_role }
      elsif plan.is_default
        { kind: 'company default' }
      else
        { kind: 'none', note: 'Not assigned yet: it only applies to deals once it is active and assigned to a person, a role, or made the company default.' }
      end
    end

    def component_json(component)
      {
        name: component.name, description: component.description.presence, component_type: component.component_type,
        gross_type: component.gross_type, rate_percent: component.rate && (component.rate.to_f * 100).round(4),
        flat_amount: component.flat_amount&.to_f, units_threshold: component.units_threshold,
        threshold_period: component.threshold_period, applies_to_role: component.applies_to_role || 'primary_salesperson',
        deal_type: component.deal_type, vertical: component.vertical, active: component.is_active,
        pays: component.calculation_description
      }.compact
    end

    def plan_json(ctx, plan, detailed: false)
      base = {
        id: "commission_plan:#{plan.id}", name: plan.name, status: status(plan), assignment: assignment(ctx, plan),
        effective_date: plan.effective_date&.iso8601, expiration_date: plan.expiration_date&.iso8601,
        location: plan.location_id ? ctx.location_names[plan.location_id] : 'All locations',
        components: plan.commission_components.ordered.map { |c| component_json(c) },
        url: plan_url(ctx, plan)
      }
      return base.compact unless detailed

      base.merge(description: plan.description.presence, editable_here: editable?(plan),
                 in_use: in_use?(plan)).compact
    end

    # A plan is in use once a deal points at it or a payment names it.
    # Payments made before the engine rework do not carry commission_plan_id,
    # so the deal link is checked as well.
    def in_use?(plan)
      plan.commission_payments.exists? || Deal.where(commission_plan_id: plan.id).exists?
    end

    def editable?(plan)
      !plan.is_active && !in_use?(plan)
    end

    # 25 and 0.25 both mean 25%. Returns [fraction, what was understood].
    def normalize_rate(value)
      return [nil, nil] if value.blank?

      number = BigDecimal(value.to_s)
      raise UserError, "rate #{value} must be more than zero." unless number.positive?

      fraction = number > 1 ? number / 100 : number
      raise UserError, "rate #{value} is more than 100%." if fraction > 1

      [fraction, "#{(fraction * 100).to_f.round(4)}%"]
    rescue ArgumentError
      raise UserError, "rate must be a number like 25 (for 25%), not #{value.inspect}."
    end

    # Builds unsaved components. Returns [components, notes for the AI].
    def build_components(ctx, plan, inputs)
      list = Array(inputs).map { |i| i.respond_to?(:to_h) ? i.to_h.deep_stringify_keys : {} }
      raise UserError, 'A plan needs at least one component.' if list.empty?
      raise UserError, 'A plan can have at most 20 components.' if list.size > 20

      notes = []
      components = list.each_with_index.map do |input, index|
        attrs = input.slice(*COMPONENT_FIELDS)
        WriteHelpers.no_dashes!(attrs['name'], attrs['description'])
        rate, understood = normalize_rate(attrs.delete('rate'))
        notes << "#{attrs['name']}: rate read as #{understood}" if understood
        # The payment engine reads gross_type for add-on components too, so an
        # add-on component without one would pay nothing.
        if attrs['component_type'] == 'addon_commission' && attrs['gross_type'].blank?
          attrs['gross_type'] = 'addon'
        end
        ctx.company.commission_components.new(
          attrs.merge('rate' => rate, 'commission_plan' => plan, 'location_id' => plan.location_id,
                      'is_active' => true, 'sequence' => index + 1)
        )
      end
      [components, notes]
    end

    # Validates the plan and every component and raises one UserError naming
    # every fix, so nothing is half saved.
    def validate!(plan, components)
      errors = []
      errors.concat(plan.errors.full_messages.map { |m| "plan: #{m}" }) unless plan.valid?
      components.each_with_index do |c, i|
        next if c.valid?

        errors.concat(c.errors.full_messages.reject { |m| m.start_with?('Commission plan') }
                       .map { |m| "component #{i + 1} (#{c.name.presence || 'unnamed'}): #{m}" })
      end
      return if errors.empty?

      raise UserError, "The plan is not valid yet, nothing was saved. Fix: #{errors.join('; ')}"
    end

    def plan_attrs(ctx, input)
      attrs = input.slice(*PLAN_FIELDS).compact
      WriteHelpers.no_dashes!(attrs['name'], attrs['description'])
      if attrs['assigned_user_id'].present?
        attrs['assigned_user_id'] = WriteHelpers.assignable_user!(ctx, attrs['assigned_user_id']).id
      end
      if attrs['location_id'].present? && !ctx.location_allowed?(attrs['location_id'])
        raise UserError, "Location #{attrs['location_id']} is not one you can use. See get_reference_data."
      end
      %w[effective_date expiration_date].each do |f|
        attrs[f] = ListTool.parse_date(attrs[f], f) if attrs.key?(f)
      end
      attrs
    end

    def snapshot(plan)
      plan.reload
      plan.attributes.slice(*PLAN_FIELDS, 'is_active', 'is_default').merge(
        'components' => plan.commission_components.ordered.map { |c| c.attributes.slice(*COMPONENT_FIELDS, 'sequence', 'is_active') }
      )
    end

    def activation_note(ctx, plan)
      "Saved as an INACTIVE draft. It pays nobody until an admin opens #{plan_url(ctx, plan)}, reviews the " \
        'components, assigns it (a person, a role, or the company default) and activates it in DealerTide. ' \
        'Tell the user this; I cannot activate commission plans or make one the default. Deals that already have ' \
        'a plan keep it; new deals pick up the active plan when their salesperson is set.'
    end

    def replace_components!(plan, components)
      plan.commission_components.each(&:destroy!)
      components.each(&:save!)
    end
  end
end
