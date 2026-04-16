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

      # Retries an HTTP request on transient errors (429, 529, 502, 503, 504).
      # Yields a block that should return a Net::HTTPResponse.
      # Returns the response on success or after exhausting retries.
      def with_retries(max_attempts: 4, base_delay: 1.0)
        attempts = 0
        loop do
          attempts += 1
          response = yield
          code = response.code.to_i

          if code.in?([429, 529, 502, 503, 504]) && attempts < max_attempts
            delay = base_delay * (2**(attempts - 1)) + rand(0.0..0.5)
            Rails.logger.warn "[#{self.class.name}] HTTP #{code}, retrying in #{delay.round(1)}s (attempt #{attempts}/#{max_attempts})"
            sleep(delay)
          else
            return response
          end
        end
      end
    end
  end
end
