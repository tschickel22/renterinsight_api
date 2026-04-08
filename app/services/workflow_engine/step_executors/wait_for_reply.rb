module WorkflowEngine
  module StepExecutors
    class WaitForReply < Base
      def call
        cfg = @step['config'] || {}
        # Timeout resume: waiting awoke, no reply arrived
        if @run.wait_until.present? && @run.wait_until <= Time.current && @run.variables['reply'].blank?
          return { status: 'success', output: { branch: 'timeout' }, next_step_id: cfg['on_timeout_branch'], wait: nil, error: {} }
        end

        # Reply arrived (resume path from handle_inbound_reply)
        if @run.variables['reply'].present?
          return { status: 'success', output: { branch: 'reply' }, next_step_id: cfg['on_reply_branch'], wait: nil, error: {} }
        end

        # First pass — pause
        timeout_hours = (cfg['timeout_hours'] || 72).to_i
        {
          status: 'success',
          output: { paused: true },
          next_step_id: nil,
          wait: { until: Time.current + timeout_hours.hours, reason: 'reply_pause' },
          error: {}
        }
      end
    end
  end
end
