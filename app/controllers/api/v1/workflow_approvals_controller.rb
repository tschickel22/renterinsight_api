module Api
  module V1
    class WorkflowApprovalsController < ApplicationController
      include RbacAuthorization
      before_action :set_company_scope
      before_action :set_approval, only: [:show, :approve, :reject]
      rbac_resource :workflow_automation,
        read_actions: [:index, :show],
        update_actions: [:approve, :reject]

      def index
        scope = @company.workflow_approvals.where(status: 'pending')
        scope = scope.where(approver_user_id: current_user.id) if current_user
        render json: scope.order(created_at: :desc).as_json
      end

      def show
        render json: @approval.as_json
      end

      def approve
        unless @approval.status == 'pending'
          return render json: { error: "approval already #{@approval.status}" }, status: :unprocessable_entity
        end
        @approval.update!(
          status: 'approved',
          approved_at: Time.current,
          approver_user_id: (@approval.approver_user_id || current_user&.id)
        )
        WorkflowEngine.resume(
          @approval.workflow_run,
          additional_variables: {
            'approval' => {
              'decision' => 'approved',
              'comment' => params[:comment],
              'user_id' => current_user&.id,
              'decided_at' => Time.current.iso8601
            }
          }
        )
        render json: @approval.reload.as_json
      end

      def reject
        unless @approval.status == 'pending'
          return render json: { error: "approval already #{@approval.status}" }, status: :unprocessable_entity
        end
        reason = params[:reason].to_s
        if reason.blank?
          return render json: { error: 'reason required' }, status: :unprocessable_entity
        end
        @approval.update!(
          status: 'rejected',
          rejection_reason: reason,
          approver_user_id: (@approval.approver_user_id || current_user&.id)
        )
        WorkflowEngine.resume(
          @approval.workflow_run,
          additional_variables: {
            'approval' => {
              'decision' => 'rejected',
              'reason' => reason,
              'user_id' => current_user&.id,
              'decided_at' => Time.current.iso8601
            }
          }
        )
        render json: @approval.reload.as_json
      end

      private

      def set_approval
        @approval = @company.workflow_approvals.find(params[:id])
      end
    end
  end
end
