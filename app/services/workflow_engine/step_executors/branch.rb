module WorkflowEngine
  module StepExecutors
    class Branch < Base
      def call
        cfg = @step['config'] || {}
        cond = cfg['condition_structured'].presence || cfg['condition']

        # Pass the LIVE entity to ConditionEvaluator so it can walk to real
        # associations AND fall through to custom_field_values. We also expose
        # the denormalized hash (owner_email, owner_name, account_name, …) as
        # `entity_hash` for conditions that pre-existing rules built against
        # those synthetic keys before this fix landed.
        ctx = {
          'entity' => @run.entity,
          'entity_hash' => WorkflowEngine.entity_hash(@run.entity),
          'variables' => @run.variables,
          'trigger' => @run.variables['trigger'] || {}
        }
        result = WorkflowEngine::ConditionEvaluator.evaluate(cond, ctx)
        next_id = result ? cfg['on_true_branch'] : cfg['on_false_branch']
        { status: 'success', output: { branch_taken: result.to_s }, next_step_id: next_id, wait: nil, error: {} }
      end
    end
  end
end
