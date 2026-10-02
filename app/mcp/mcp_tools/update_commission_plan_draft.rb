# frozen_string_literal: true

module McpTools
  # Edits an inactive plan no deal uses yet. Components given replace the
  # plan's components entirely; leave them out to change only plan fields.
  class UpdateCommissionPlanDraft < Base
    tool_name 'update_commission_plan_draft'
    title 'Edit a draft commission plan'
    description 'Change an INACTIVE commission plan that no deal uses yet: name, description, assignment, dates, ' \
                'location, and its components (the list given replaces the current components; read the plan with ' \
                'get_commission_plan first and send the full list). Active plans and plans already on deals are ' \
                'changed in DealerTide. If anything is not valid you get every fix and nothing is saved.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'commission_plan:4' },
        name: { type: 'string' },
        description: { type: 'string' },
        assigned_user_id: { type: 'integer' },
        assigned_role: { type: 'string' },
        effective_date: { type: 'string' },
        expiration_date: { type: 'string' },
        location_id: { type: 'integer' },
        components: CommissionPlanSupport::COMPONENT_SCHEMA
      },
      required: %w[id]
    )
    writes!(destructive: true)

    def self.perform(ctx, id:, components: nil, **rest)
      CommissionPlanSupport.require!(ctx, 'update', components: components.nil? ? nil : 'create')
      plan = CommissionPlanSupport.find_plan(ctx, id)
      if plan.is_active
        raise UserError, 'That plan is active, so it is changed in DealerTide, not here. I can draft a new version instead.'
      end
      if CommissionPlanSupport.in_use?(plan)
        raise UserError, 'Deals already use that plan, so it is changed in DealerTide, not here. I can draft a new version instead.'
      end
      if rest[:assigned_user_id].present? && rest[:assigned_role].present?
        raise UserError, 'Assign the plan to a person or a role, not both.'
      end

      before = CommissionPlanSupport.snapshot(plan)
      attrs = CommissionPlanSupport.plan_attrs(ctx, rest.transform_keys(&:to_s))
      attrs['assigned_role'] = nil if attrs['assigned_user_id'].present?
      attrs['assigned_user_id'] = nil if attrs['assigned_role'].present?
      plan.assign_attributes(attrs)
      built, notes = components.nil? ? [nil, []] : CommissionPlanSupport.build_components(ctx, plan, components)
      CommissionPlanSupport.validate!(plan, built || [])
      raise UserError, 'Nothing to change.' if built.nil? && !plan.changed?

      CommissionPlan.transaction do
        plan.save!
        CommissionPlanSupport.replace_components!(plan, built) if built
      end
      ctx.record_change(action: 'updated', record: plan, before: before, after: CommissionPlanSupport.snapshot(plan))

      Base::Result.new(payload: {
        updated: CommissionPlanSupport.plan_json(ctx, plan),
        rate_notes: notes.presence,
        next_step: CommissionPlanSupport.activation_note(ctx, plan)
      }.compact, count: 1)
    end
  end
end
