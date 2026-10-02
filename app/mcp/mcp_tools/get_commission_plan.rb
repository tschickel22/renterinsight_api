# frozen_string_literal: true

module McpTools
  class GetCommissionPlan < Base
    tool_name 'get_commission_plan'
    title 'Read a commission plan'
    description 'One commission plan in full: who it applies to, dates, every component in plain words and in the ' \
                'shape create_commission_plan_draft takes, and whether it can still be edited here (only inactive ' \
                'plans no deal uses). Id from list_commission_plans, e.g. commission_plan:4. Read only.'
    input_schema(properties: { id: { type: 'string' } }, required: ['id'])
    read_only!

    def self.perform(ctx, id:)
      CommissionPlanSupport.require!(ctx, 'read')
      plan = CommissionPlanSupport.find_plan(ctx, id)
      Base::Result.new(payload: CommissionPlanSupport.plan_json(ctx, plan, detailed: true), count: 1)
    end
  end
end
