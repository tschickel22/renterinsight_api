# frozen_string_literal: true

module McpTools
  # Shared by create_workflow_draft and update_workflow_draft: the input
  # shape, and the checks that run before anything is saved.
  module WorkflowDraftSupport
    RECORD_TYPES = %w[Lead Deal Contact Account ServiceTicket].freeze

    # call_webhook sends data to an outside URL once the rule is active: an
    # export path, and easy to miss when a person reviews a long draft.
    BLOCKED_STEP_TYPES = %w[call_webhook].freeze

    SCHEMA_PROPERTIES = {
      name: { type: 'string' },
      description: { type: 'string' },
      record_type: { type: 'string', enum: RECORD_TYPES, description: 'What the workflow runs on' },
      trigger: {
        type: 'object',
        description: "What starts it, e.g. {\"event_type\": \"lead.created\"}. Event types: #{WorkflowRuleValidator::KNOWN_EVENT_TYPES.join(', ')}"
      },
      conditions: {
        type: 'object',
        description: 'Optional filter: {"logic": "and", "conditions": [{"field": "status", "operator": "equals", "value": "new"}]}. ' \
                     'Operators: equals, not_equals, contains, in, gt, lt, gte, lte, is_set, is_not_set'
      },
      steps: {
        type: 'object',
        description: 'Graph of steps: {"nodes": [{"id": "step_1", "type": "send_email", "config": {"to": "{{entity.email}}", ' \
                     '"subject": "...", "body": "..."}}], "edges": [{"source": "step_1", "target": "step_2"}]}. Step types: ' \
                     "#{(WorkflowRuleValidator::VALID_STEP_TYPES - BLOCKED_STEP_TYPES).join(', ')}. " \
                     'wait needs duration and unit (minutes, hours, days); send_sms needs to and body; ' \
                     'create_activity takes subject, activity_type, assigned_to, due_in_hours; enroll_in_nurture needs nurture_sequence_id.'
      },
      halt_on_reply: { type: 'string', enum: %w[false true branch] }
    }.freeze

    module_function

    # Validates an unsaved or changed rule. Raises UserError listing what to fix.
    def check!(rule)
      nodes = Array((rule.steps || {})['nodes'])
      blocked = nodes.map { |n| n['type'] } & BLOCKED_STEP_TYPES
      if blocked.any?
        raise UserError, 'Webhook steps (call_webhook) cannot be added through the AI connector because they send ' \
                         'data outside DealerTide. Leave that step out; the user can add it in DealerTide after reviewing the draft.'
      end

      copy = nodes.flat_map { |n| (n['config'] || {}).values_at('subject', 'body', 'message') }.grep(String)
      WriteHelpers.no_dashes!(copy)

      result = WorkflowRuleValidator.new(rule).validate
      unless result.valid?
        raise UserError, "The workflow is not valid yet, nothing was saved. Fix: #{result.errors.join('; ')}"
      end

      result.warnings
    end

    def normalize(value)
      value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : value
    end
  end
end
