# frozen_string_literal: true

module McpTools
  class GetWorkflow < Base
    tool_name 'get_workflow'
    title 'Read a workflow'
    description 'One workflow automation in full: trigger, conditions and steps, in the same shape ' \
                'create_workflow_draft and update_workflow_draft take. Id from list_workflows, e.g. workflow:4. Read only.'
    input_schema(properties: { id: { type: 'string' } }, required: ['id'])
    read_only!

    def self.perform(ctx, id:)
      MarketingAccess.require_workflows!(ctx, 'read')
      rule = ctx.company.workflow_rules.find(id.to_s.delete_prefix('workflow:').to_i)
      payload = {
        id: "workflow:#{rule.id}", name: rule.name, description: rule.description, status: rule.status,
        record_type: rule.entity_type, trigger: rule.trigger, conditions: rule.conditions, steps: rule.steps,
        halt_on_reply: rule.halt_on_reply, url: MarketingAccess.workflow_url(ctx, rule),
        editable_here: rule.status == 'draft'
      }
      Base::Result.new(payload: payload, count: 1)
    end
  end
end
