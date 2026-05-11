module WorkflowEngine
  module StepExecutors
    class SendEmail < Base
      def call
        # Guard: if this is a Champion lead and it's already been accepted/declined,
        # skip this email and end the run. Returning next_step_id: nil completes the run.
        entity = @run.entity
        if entity.is_a?(Lead) && entity.champion_salesforce_id.present?
          entity.reload
          unless entity.champion_status == 'new'
            Rails.logger.info "[SendEmail] Champion lead #{entity.id} already #{entity.champion_status}, skipping reminder"
            return { status: 'success', output: { skipped: true, reason: 'champion_lead_already_actioned' }, next_step_id: nil, wait: nil, error: {} }
          end
        end

        config = @step['config'] || {}
        to = resolve_variables(config['to'].to_s)
        subject = resolve_variables(config['subject'].to_s)
        body = resolve_variables(config['body'].to_s)

        # Use the entity's owner as the sending user so their email
        # connection (Gmail OAuth, etc.) is used instead of falling
        # back to platform-level AWS SES credentials.
        sending_user = @run.entity.try(:owner)

        # If 'to' resolved to blank (e.g. {{entity.owner_email}} from stale
        # variables snapshot taken before round-robin), fall back to the
        # live entity owner's email.
        if to.blank? && sending_user&.email.present?
          to = sending_user.email
          Rails.logger.info "[SendEmail] 'to' was blank, using live owner email: #{to}"
        end

        Rails.logger.info "[SendEmail] run=#{@run.id} step=#{@step['id']} to=#{to}"

        comm = nil
        begin
          result = CommunicationService.send_email(
            communicable: @run.entity,
            to: to,
            subject: subject,
            body: body,
            user: sending_user,
            metadata: { workflow_run_id: @run.id, step_id: @step['id'] }
          )
          comm = result if result.is_a?(Communication)
          comm ||= Communication.where(communicable: @run.entity, direction: 'outbound', channel: 'email')
                                .order(created_at: :desc).first
        rescue => e
          Rails.logger.error "[SendEmail] CommunicationService.send_email failed: #{e.message} — adapt if signature differs"
          # Fallback: create a Communication directly so reply-pause still has a parent
          begin
            comm = Communication.create!(
              communicable: @run.entity,
              direction: 'outbound',
              channel: 'email',
              status: 'sent',
              subject: subject.presence || '(no subject)',
              body: body.presence || '(empty)',
              to_address: to.presence || 'unknown@example.com',
              from_address: 'workflow@renterinsight.test',
              sent_at: Time.current,
              company: (@run.entity.respond_to?(:company) ? @run.entity.company : nil),
              metadata: { workflow_run_id: @run.id, step_id: @step['id'] }
            )
          rescue => e2
            Rails.logger.error "[SendEmail] fallback Communication.create! failed: #{e2.message}"
            return { status: 'failed', output: {}, next_step_id: nil, wait: nil, error: { message: e.message } }
          end
        end

        if comm
          begin
            comm.update_columns(workflow_run_id: @run.id, workflow_step_id: @step['id'].to_s)
          rescue => e
            Rails.logger.warn "[SendEmail] failed to stamp workflow_run_id on Communication: #{e.message}"
          end
        end

        { status: 'success', output: { to: to, communication_id: comm&.id }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end
    end
  end
end
