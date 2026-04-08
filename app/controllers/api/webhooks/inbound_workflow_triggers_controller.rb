module Api
  module Webhooks
    class InboundWorkflowTriggersController < ApplicationController
      skip_before_action :authenticate, raise: false
      skip_before_action :set_current_attributes, raise: false

      def trigger
        token = params[:token]
        inbound = WorkflowInboundTrigger.find_by(token: token, active: true)
        return render json: { error: 'not_found' }, status: :not_found unless inbound

        rule = inbound.workflow_rule
        return render json: { error: 'rule_inactive' }, status: :unprocessable_entity unless rule && rule.status == 'active'

        first_node = rule.steps.dig('nodes', 0)
        return render json: { error: 'invalid_rule' }, status: :unprocessable_entity unless first_node

        run = WorkflowRun.create!(
          company: rule.company,
          workflow_rule: rule,
          entity_type: 'InboundWebhook',
          entity_id: 0,
          status: 'pending',
          current_step_id: first_node['id'],
          started_at: Time.current,
          variables: {
            'trigger' => request.request_parameters,
            'inbound_trigger_id' => inbound.id
          },
          rule_snapshot: rule.steps
        )

        inbound.update(last_triggered_at: Time.current)
        ProcessWorkflowStepJob.perform_later(run.id)
        render json: { run_id: run.id, status: 'accepted' }, status: :accepted
      end
    end
  end
end
