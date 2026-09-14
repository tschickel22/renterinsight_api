module WorkflowEngine
  module StepExecutors
    class SendSms < Base
      def call
        config = @step['config'] || {}
        to = resolve_variables(config['to'].to_s)
        body = resolve_variables(config['body'].to_s)

        Rails.logger.info "[SendSms] run=#{@run.id} step=#{@step['id']} to=#{to}"

        begin
          result = CommunicationService.send_sms(
            communicable: @run.entity,
            to: to,
            body: body,
            metadata: { workflow_run_id: @run.id, step_id: @step['id'] }
          )
        rescue => e
          Rails.logger.error "[SendSms] CommunicationService.send_sms failed: #{e.message} — adapt if signature differs"
          return { status: 'failed', output: {}, next_step_id: nil, wait: nil, error: { message: e.message } }
        end

        # A reply finds its run through the outbound message's workflow_run_id
        # column (Communication#notify_workflow_of_inbound). send_email set it;
        # this only put the run id in metadata, so a wait_for_reply after a text
        # never heard the answer.
        communication = result.is_a?(Hash) ? result[:communication] : nil
        if communication.respond_to?(:persisted?) && communication.persisted?
          communication.update_column(:workflow_run_id, @run.id)
        end

        { status: 'success', output: { to: to }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end
    end
  end
end
