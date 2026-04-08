module WorkflowEngine
  module StepExecutors
    class Base
      def initialize(run:, step:)
        @run = run
        @step = step
      end

      def call
        raise NotImplementedError
      end

      protected

      def resolve_variables(template_string)
        WorkflowEngine::VariableResolver.resolve(template_string, @run.variables)
      end

      def next_step_from_edges
        edges = @run.rule_snapshot['edges'] || []
        edge = edges.find { |e| e['source'] == @step['id'] }
        edge && edge['target']
      end
    end
  end
end
