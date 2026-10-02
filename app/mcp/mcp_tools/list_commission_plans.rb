# frozen_string_literal: true

module McpTools
  class ListCommissionPlans < ListTool
    tool_name 'list_commission_plans'
    title 'List commission plans'
    description 'List commission plans: status (inactive, current, future, expired), who each applies to (a person, ' \
                'a role, or the company default), location, and each component in plain words. Plan design only; ' \
                'what any person earned is not available here.'
    input_schema(
      properties: {
        status: { type: 'string', enum: %w[inactive current future expired any] },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: 'any', limit: 20)
      CommissionPlanSupport.require!(ctx, 'read')
      rel = ctx.scope_locations(ctx.company.commission_plans, include_unlocated: true)
               .includes(:commission_components).order(:display_order, created_at: :desc)
      rows = rel.limit(ctx.row_limit(limit)).to_a
      rows = rows.select { |p| CommissionPlanSupport.status(p) == status } if status.present? && status != 'any'
      items = rows.map { |p| CommissionPlanSupport.plan_json(ctx, p) }
      Base::Result.new(payload: { count: items.size, items: items }, count: items.size)
    end
  end
end
