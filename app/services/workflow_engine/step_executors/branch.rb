module WorkflowEngine
  module StepExecutors
    class Branch < Base
      def call
        cfg = @step['config'] || {}
        cond = cfg['condition_structured'].presence || cfg['condition']
        ctx = {
          'entity' => @run.entity&.as_json || {},
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
