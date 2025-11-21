module Api
  module Crm
    class ApprovalsController < ApplicationController
      include RbacAuthorization
      rbac_resource :deals,
        read_actions: [:index, :show],
        create_actions: [:create],
        update_actions: [:update, :approve, :reject, :cancel, :escalate],
        delete_actions: [:destroy]

      before_action :set_company_scope
      before_action :set_deal, except: [:index, :show], if: -> { params[:deal_id].present? }
      before_action :set_workflow, only: [:show, :update, :destroy, :approve, :reject, :cancel, :escalate]

      # GET /api/crm/approvals (all approvals) OR
      # GET /api/crm/deals/:deal_id/approvals (deal-specific)
      def index
        workflows = if params[:deal_id].present? && params[:action] == 'index' && request.path.include?('/deals/')
                      # For nested routes: /api/crm/deals/:deal_id/approvals
                      deal = @company.deals.find_by(id: params[:deal_id])
                      return render json: { error: 'Deal not found' }, status: :not_found unless deal
                      deal.approval_workflows
                    elsif params[:deal_id].present?
                      # For root routes with deal_id filter: /api/crm/approvals?deal_id=123
                      deal = @company.deals.find_by(id: params[:deal_id])
                      return render json: { error: 'Deal not found' }, status: :not_found unless deal
                      ApprovalWorkflow.where(deal_id: deal.id)
                    else
                      # All approvals for this company's deals
                      deal_ids = @company.deals.pluck(:id)
                      ApprovalWorkflow.where(deal_id: deal_ids)
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
        workflow.requested_by_id = current_user&.id
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
        
        step = @workflow.approval_steps.find_by(id: step_id)
        return render json: { error: 'Step not found' }, status: :not_found unless step
        
        # Create approval action
        action = step.approval_actions.create(
          user_id: current_user&.id,
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
            approved_by_id: current_user&.id,
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
        
        step = @workflow.approval_steps.find_by(id: step_id)
        return render json: { error: 'Step not found' }, status: :not_found unless step
        
        # Create rejection action
        action = step.approval_actions.create(
          user_id: current_user&.id,
          action_type: 'rejected',
          notes: notes,
          actioned_at: Time.current
        )
        
        # Update step and workflow status
        step.update(status: 'rejected')
        @workflow.update(
          status: 'rejected',
          approved_by_id: current_user&.id,
          approved_at: Time.current
        )
        
        render json: workflow_json(@workflow, detailed: true)
      end

      # POST /api/crm/deals/:deal_id/approvals/:id/cancel
      def cancel
        notes = params[:notes]
        
        @workflow.update(
          status: 'cancelled',
          approved_by_id: current_user&.id,
          approved_at: Time.current
        )
        
        # Add note to all pending steps
        @workflow.approval_steps.where(status: 'pending').each do |step|
          step.approval_actions.create(
            user_id: current_user&.id,
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
          # Verify the user belongs to the same company
          target_user = @company.users.find_by(id: escalate_to)
          if target_user
            @workflow.approval_steps.create(
              approver_user_id: target_user.id,
              step_order: @workflow.approval_steps.maximum(:step_order).to_i + 1,
              status: 'pending',
              required_action: 'approve',
              notes: "Escalated from previous approver: #{reason}"
            )
          end
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

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [ApprovalsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [ApprovalsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [ApprovalsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [ApprovalsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_deal
        @deal = @company.deals.find_by(id: params[:deal_id])
        unless @deal
          render json: { error: 'Deal not found or access denied' }, status: :not_found
          return
        end
      end

      def set_workflow
        @workflow = if params[:deal_id].present?
                      deal = @company.deals.find_by(id: params[:deal_id])
                      return render json: { error: 'Deal not found' }, status: :not_found unless deal
                      deal.approval_workflows.find_by(id: params[:id])
                    else
                      # Find workflow through company's deals
                      deal_ids = @company.deals.pluck(:id)
                      ApprovalWorkflow.where(deal_id: deal_ids).find_by(id: params[:id])
                    end
        
        unless @workflow
          render json: { error: 'Approval workflow not found or access denied' }, status: :not_found
          return
        end
      end

      def workflow_params
        params.require(:approval_workflow).permit(
          :workflow_type, :required_amount, :reason, :notes
        )
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
