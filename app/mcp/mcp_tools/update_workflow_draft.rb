# frozen_string_literal: true

module McpTools
  # Edits a workflow that is still a draft. A live (active or paused) workflow
  # is refused: editing it would change what is running for customers now.
  class UpdateWorkflowDraft < Base
    tool_name 'update_workflow_draft'
    title 'Edit a draft workflow'
    description 'Change a workflow that is still a DRAFT (id from list_workflows or create_workflow_draft). Send only ' \
                'the parts to change. A workflow that is already active or paused cannot be edited here, because that ' \
                'would change what is running now; offer to create a new draft instead, or the user can edit it in DealerTide.'
    input_schema(properties: { id: { type: 'string' } }.merge(WorkflowDraftSupport::SCHEMA_PROPERTIES), required: %w[id])
    writes!

    FIELDS = { name: :name, description: :description, record_type: :entity_type, trigger: :trigger,
               conditions: :conditions, steps: :steps, halt_on_reply: :halt_on_reply }.freeze

    def self.perform(ctx, id:, **changes)
      MarketingAccess.require_workflows!(ctx, 'update')
      rule = ctx.company.workflow_rules.find(id.to_s.delete_prefix('workflow:').to_i)
      unless rule.status == 'draft'
        raise UserError, "#{rule.name} is #{rule.status}, so I cannot edit it: that would change what is running now. " \
                         'I can create a new draft with your changes instead, or you can edit it in DealerTide at ' \
                         "#{MarketingAccess.workflow_url(ctx, rule)}."
      end

      attrs = changes.slice(*FIELDS.keys).to_h { |k, v| [FIELDS[k], WorkflowDraftSupport.normalize(v)] }
      raise UserError, 'Nothing to change.' if attrs.empty?

      before = rule.attributes.slice(*attrs.keys.map(&:to_s))
      rule.assign_attributes(attrs)
      warnings = WorkflowDraftSupport.check!(rule)
      rule.save!
      ctx.record_change(action: 'updated', record: rule, before: before.merge('status' => 'draft'),
                        after: rule.attributes.slice(*attrs.keys.map(&:to_s)).merge('status' => 'draft'))

      Base::Result.new(payload: {
        draft: { id: "workflow:#{rule.id}", name: rule.name, status: 'draft', url: MarketingAccess.workflow_url(ctx, rule) },
        warnings: warnings,
        next_step: MarketingAccess.workflow_activation_note(ctx, rule)
      }, count: 1)
    end
  end
end
