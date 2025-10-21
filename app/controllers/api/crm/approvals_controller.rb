module Api
  module Crm
    class ApprovalsController < ApplicationController
      before_action :set_deal, except: [:index, :show], if: -> { params[:deal_id].present? }
      before_action :set_workflow, only: [:show, :update, :destroy, :approve, :reject, :cancel, :escalate]

      # GET /api/crm/approvals (all approvals) OR
      # GET /api/crm/deals/:deal_id/approvals (deal-specific)
      def index
        workflows = if params[:deal_id].present? && params[:action] == 'index' && request.path.include?('/deals/')
                      # For nested routes: /api/crm/deals/:deal_id/approvals
                      Deal.find(params[:deal_id]).approval_workflows
                    elsif params[:deal_id].present?
                      # For root routes with deal_id filter: /api/crm/approvals?deal_id=123
                      ApprovalWorkflow.where(deal_id: params[:deal_id])
                    else
                      ApprovalWorkflow.all
                    end
        
        workflows = workflows.includes(:deal, approval_steps: :approval_actions)
                            .order(created_at: :desc)
        
        # Filter by status if provided
        workflows = workflows.where(status: params[:status]) if params[:status].present?
        
        render json: workflows.map { |w| workflow_json(w) }
      end

      # GET /api/crm/approvals/:id OR
      # GET /api/crm/deals/:deal_id/approvals/:id
      def show
        render json: workflow_json(@workflow, detailed: true)
      end

      # POST /api/crm/deals/:deal_id/approvals
      def create
        workflow = @deal.approval_workflows.new(workflow_params)
        workflow.requested_by_id = current_user_id
        workflow.status = 'pending'
        
        if workflow.save
          render json: workflow_json(workflow, detailed: true), status: :created
        else
          render json: { errors: workflow.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/crm/deals/:deal_id/approvals/:id
      def update
        if @workflow.update(workflow_params)
          render json: workflow_json(@workflow, detailed: true)
        else
          render json: { errors: @workflow.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/crm/deals/:deal_id/approvals/:id/approve
      def approve
        step_id = params[:step_id]
        notes = params[:notes]
        
        if step_id.blank?
          render json: { error: 'Step ID is required' }, status: :bad_request
          return
        end
        
        step = @workflow.approval_steps.find(step_id)
        
        # Create approval action
        action = step.approval_actions.create(
          user_id: current_user_id,
          action_type: 'approved',
          notes: notes,
          actioned_at: Time.current
        )
        
        # Update step status
        step.update(status: 'approved')
        
        # Check if all steps are approved
        if @workflow.approval_steps.all? { |s| s.status == 'approved' }
          @workflow.update(
            status: 'approved',
            approved_by_id: current_user_id,
            approved_at: Time.current
          )
        end
        
        render json: workflow_json(@workflow, detailed: true)
      end

      # POST /api/crm/deals/:deal_id/approvals/:id/reject
      def reject
        step_id = params[:step_id]
        notes = params[:notes]
        
        if step_id.blank?
          render json: { error: 'Step ID is required' }, status: :bad_request
          return
        end
        
        step = @workflow.approval_steps.find(step_id)
        
        # Create rejection action
        action = step.approval_actions.create(
          user_id: current_user_id,
          action_type: 'rejected',
          notes: notes,
          actioned_at: Time.current
        )
        
        # Update step and workflow status
        step.update(status: 'rejected')
        @workflow.update(
          status: 'rejected',
          approved_by_id: current_user_id,
          approved_at: Time.current
        )
        
        render json: workflow_json(@workflow, detailed: true)
      end

      # POST /api/crm/deals/:deal_id/approvals/:id/cancel
      def cancel
        notes = params[:notes]
        
        @workflow.update(
          status: 'cancelled',
          approved_by_id: current_user_id,
          approved_at: Time.current
        )
        
        # Add note to all pending steps
        @workflow.approval_steps.where(status: 'pending').each do |step|
          step.approval_actions.create(
            user_id: current_user_id,
            action_type: 'cancelled',
            notes: notes,
            actioned_at: Time.current
          )
          step.update(status: 'cancelled')
        end
        
        render json: workflow_json(@workflow, detailed: true)
      end

      # POST /api/crm/approvals/:id/escalate
      def escalate
        reason = params[:reason]
        escalate_to = params[:escalate_to]
        
        @workflow.update(
          status: 'escalated',
          notes: "Escalated: #{reason}"
        )
        
        # If escalate_to is provided, add a new approval step
        if escalate_to.present?
          @workflow.approval_steps.create(
            approver_user_id: escalate_to,
            step_order: @workflow.approval_steps.maximum(:step_order).to_i + 1,
            status: 'pending',
            required_action: 'approve',
            notes: "Escalated from previous approver: #{reason}"
          )
        end
        
        render json: workflow_json(@workflow, detailed: true)
      end

      # DELETE /api/crm/deals/:deal_id/approvals/:id
      def destroy
        if @workflow.status != 'pending'
          render json: { error: 'Cannot delete non-pending approval workflow' }, status: :unprocessable_entity
          return
        end
        
        @workflow.destroy
        head :no_content
      end

      private

      def set_deal
        @deal = Deal.find(params[:deal_id])
      end

      def set_workflow
        @workflow = if params[:deal_id].present?
                      Deal.find(params[:deal_id]).approval_workflows.find(params[:id])
                    else
                      ApprovalWorkflow.find(params[:id])
                    end
      end

      def workflow_params
        params.require(:approval_workflow).permit(
          :workflow_type, :required_amount, :reason, :notes
        )
      end

      def current_user_id
        # This should be set by your authentication system
        current_user&.id
      end

      def workflow_json(workflow, detailed: false)
        base = {
          id: workflow.id,
          dealId: workflow.deal_id,
          workflowType: workflow.workflow_type,
          status: workflow.status,
          requiredAmount: workflow.required_amount,
          reason: workflow.reason,
          notes: workflow.notes,
          requestedById: workflow.requested_by_id,
          requestedByName: workflow.requested_by&.name,
          approvedById: workflow.approved_by_id,
          approvedByName: workflow.approved_by&.name,
          approvedAt: workflow.approved_at&.iso8601,
          createdAt: workflow.created_at&.iso8601,
          updatedAt: workflow.updated_at&.iso8601
        }
        
        if detailed
          base.merge!(
            steps: workflow.approval_steps.order(:step_order).map { |s| approval_step_json(s) },
            deal: {
              id: workflow.deal.id,
              name: workflow.deal.name,
              value: workflow.deal.value,
              stage: workflow.deal.stage
            }
          )
        end
        
        base
      end

      def approval_step_json(step)
        {
          id: step.id,
          stepOrder: step.step_order,
          approverUserId: step.approver_user_id,
          approverUserName: step.approver_user&.name,
          status: step.status,
          requiredAction: step.required_action,
          notes: step.notes,
          actions: step.approval_actions.order(actioned_at: :desc).map { |a| approval_action_json(a) }
        }
      end

      def approval_action_json(action)
        {
          id: action.id,
          userId: action.user_id,
          userName: action.user&.name,
          actionType: action.action_type,
          notes: action.notes,
          actionedAt: action.actioned_at&.iso8601
        }
      end
    end
  end
end
