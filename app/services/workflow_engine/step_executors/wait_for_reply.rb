module WorkflowEngine
  module StepExecutors
    class WaitForReply < Base
      # The wait keeps its own start and deadline in run variables.
      #
      # It used to read run.wait_until to spot a timeout, but every wake-up path
      # (WorkflowEngine.resume, ProcessWorkflowStepJob) clears wait_until before
      # the step runs again, so the timeout branch could never be taken: a lead
      # who never replied was paused again for another timeout_hours, forever.
      # And any reply ever received stayed in variables['reply'], so a second
      # wait in the same run took the reply branch at once. Only a reply that
      # arrived after THIS wait began counts.
      def call
        cfg = @step['config'] || {}
        state = @run.variables&.dig(state_key)

        if state.is_a?(Hash)
          started_at = parse_time(state['started_at'])
          deadline = parse_time(state['deadline'])

          if replied_since?(started_at)
            clear_state
            return { status: 'success', output: { branch: 'reply' }, next_step_id: cfg['on_reply_branch'], wait: nil, error: {} }
          end

          if deadline.nil? || deadline <= Time.current
            clear_state
            return { status: 'success', output: { branch: 'timeout' }, next_step_id: cfg['on_timeout_branch'], wait: nil, error: {} }
          end

          # Woken early with no reply: keep waiting until the original deadline.
          return pause_until(deadline)
        end

        timeout_hours = (cfg['timeout_hours'] || 72).to_i
        deadline = Time.current + timeout_hours.hours
        @run.update!(variables: (@run.variables || {}).merge(
          state_key => { 'started_at' => Time.current.iso8601(6), 'deadline' => deadline.iso8601(6) }
        ))
        pause_until(deadline)
      end

      private

      def state_key
        "reply_wait_#{@step['id']}"
      end

      def pause_until(deadline)
        { status: 'success', output: { paused: true }, next_step_id: nil, wait: { until: deadline, reason: 'reply_pause' }, error: {} }
      end

      def replied_since?(started_at)
        reply = @run.variables&.dig('reply')
        return false unless reply.is_a?(Hash)

        received_at = parse_time(reply['received_at'])
        received_at.present? && (started_at.nil? || received_at >= started_at)
      end

      def clear_state
        @run.update!(variables: (@run.variables || {}).except(state_key))
      end

      def parse_time(value)
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError
        nil
      end
    end
  end
end
