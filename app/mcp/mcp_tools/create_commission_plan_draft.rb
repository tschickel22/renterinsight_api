# frozen_string_literal: true

module McpTools
  # Builds a commission plan and its components, always INACTIVE: a deal only
  # picks up an active, current plan, so a draft pays nobody until an admin
  # activates it in DealerTide. There is no activate tool.
  class CreateCommissionPlanDraft < Base
    tool_name 'create_commission_plan_draft'
    title 'Draft a commission plan'
    description 'Build a commission plan with its components and save it as an INACTIVE draft that pays nobody ' \
                'until an admin activates it in DealerTide. Test the design with simulate_commission_plan first. ' \
                'Assign it to a person (assigned_user_id from get_reference_data) or a role key; making it the ' \
                'company default is done by an admin on activation. If anything is not valid you get every fix and ' \
                'nothing is saved.'
    input_schema(
      properties: {
        name: { type: 'string' },
        description: { type: 'string' },
        assigned_user_id: { type: 'integer' },
        assigned_role: { type: 'string', description: "The salesperson's role key in DealerTide" },
        wants_default: { type: 'boolean', description: 'The user wants this to be the company default plan' },
        effective_date: { type: 'string', description: '2026-11-01' },
        expiration_date: { type: 'string' },
        location_id: { type: 'integer', description: 'Leave out for all locations' },
        components: CommissionPlanSupport::COMPONENT_SCHEMA
      },
      required: %w[name components]
    )
    writes!(destructive: false)

    def self.perform(ctx, name:, components:, wants_default: false, **rest)
      CommissionPlanSupport.require!(ctx, 'create', components: 'create')
      if rest[:assigned_user_id].present? && rest[:assigned_role].present?
        raise UserError, 'Assign the plan to a person or a role, not both.'
      end

      attrs = CommissionPlanSupport.plan_attrs(ctx, rest.transform_keys(&:to_s).merge('name' => name.to_s.strip.first(255)))
      plan = ctx.company.commission_plans.new(attrs.merge('is_active' => false, 'is_default' => false))
      built, notes = CommissionPlanSupport.build_components(ctx, plan, components)
      CommissionPlanSupport.validate!(plan, built)
      CommissionPlan.transaction do
        plan.save!
        built.each(&:save!)
      end
      ctx.record_change(action: 'created', record: plan, after: CommissionPlanSupport.snapshot(plan))

      Base::Result.new(payload: {
        draft: CommissionPlanSupport.plan_json(ctx, plan),
        rate_notes: notes.presence,
        default_note: (if wants_default
                         'Saved as a draft, not the default. An admin makes it the company default when activating it in DealerTide.'
                       end),
        next_step: CommissionPlanSupport.activation_note(ctx, plan)
      }.compact, count: 1)
    end
  end
end
