module WorkflowEngine
  module StepExecutors
    class RequireApproval < Base
      def call
        cfg = @step['config'] || {}

        if @run.variables['approval'].present?
          decision = @run.variables.dig('approval', 'decision')
          next_id = case decision
                    when 'approved' then cfg['on_approved_branch']
                    when 'rejected' then cfg['on_rejected_branch']
                    else cfg['on_expired_branch']
                    end
          return { status: 'success', output: { decision: decision }, next_step_id: next_id, wait: nil, error: {} }
        end

        expires_at = Time.current + (cfg['expires_in_hours'] || 24).to_i.hours
        approval = WorkflowApproval.create!(
          workflow_run: @run,
          step_id: @step['id'],
          company_id: @run.company_id,
          status: 'pending',
          approver_user_id: cfg['approver_user_id'],
          expires_at: expires_at
        )

        begin
          if defined?(NotificationBroadcast)
            NotificationBroadcast.toast(
              user_id: cfg['approver_user_id'],
              message: "Workflow approval required (run ##{@run.id})"
            )
          end
        rescue => e
          Rails.logger.warn "[RequireApproval] notify failed: #{e.message}"
        end

        {
          status: 'success',
          output: { approval_id: approval.id },
          next_step_id: nil,
          wait: { until: expires_at, reason: 'approval' },
          error: {}
        }
      end
    end
  end
end
