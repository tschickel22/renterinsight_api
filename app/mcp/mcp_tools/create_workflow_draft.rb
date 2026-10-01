# frozen_string_literal: true

module McpTools
  # Builds a workflow automation and saves it as a DRAFT. Drafts have no event
  # subscriptions and every dispatch path requires 'active', so nothing runs
  # until a person activates it in DealerTide. There is no activate tool.
  class CreateWorkflowDraft < Base
    tool_name 'create_workflow_draft'
    title 'Draft a workflow automation'
    description 'Build a workflow automation and save it as a DRAFT. It does nothing until a person reviews and ' \
                'activates it in DealerTide; this connector cannot activate, pause or delete workflows. Use ' \
                'get_reference_data for status and stage keys, and list_nurture_sequences for sequence ids. If it ' \
                'is not valid yet, you get the list of fixes and nothing is saved.'
    input_schema(properties: WorkflowDraftSupport::SCHEMA_PROPERTIES, required: %w[name record_type trigger steps])
    writes!

    def self.perform(ctx, name:, record_type:, trigger:, steps:, description: nil, conditions: nil, halt_on_reply: 'false')
      MarketingAccess.require_workflows!(ctx, 'create')
      rule = ctx.company.workflow_rules.new(
        name: name.to_s.strip.first(200), description: description, entity_type: record_type, status: 'draft',
        trigger: WorkflowDraftSupport.normalize(trigger),
        conditions: WorkflowDraftSupport.normalize(conditions) || {},
        steps: WorkflowDraftSupport.normalize(steps), halt_on_reply: halt_on_reply.to_s,
        created_by_user_id: ctx.user.id
      )
      warnings = WorkflowDraftSupport.check!(rule)
      rule.save!
      ctx.record_change(action: 'created', record: rule, after: Undo.workflow_snapshot(rule))

      Base::Result.new(payload: {
        draft: { id: "workflow:#{rule.id}", name: rule.name, status: 'draft', url: MarketingAccess.workflow_url(ctx, rule) },
        warnings: warnings,
        next_step: MarketingAccess.workflow_activation_note(ctx, rule)
      }, count: 1)
    end
  end
end
