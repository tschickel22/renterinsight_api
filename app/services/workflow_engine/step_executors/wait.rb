module WorkflowEngine
  module StepExecutors
    class Wait < Base
      def call
        config = @step['config'] || {}
        duration = (config['duration'] || 0).to_i
        unit = (config['unit'] || 'minutes').to_s
        unit = 'minutes' unless %w[minutes hours days].include?(unit)

        wait_until = Time.current + duration.send(unit)
        Rails.logger.info "[Wait] run=#{@run.id} step=#{@step['id']} until=#{wait_until}"

        {
          status: 'success',
          output: { wait_until: wait_until },
          next_step_id: next_step_from_edges,
          wait: { until: wait_until, reason: 'delay' },
          error: {}
        }
      end
    end
  end
end
