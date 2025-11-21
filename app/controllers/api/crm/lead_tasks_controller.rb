module Api
  module Crm
    class LeadTasksController < ApplicationController
      include RbacAuthorization
      rbac_resource :crm

      before_action :set_company_scope
      before_action :set_lead

      def create
        t = @lead.lead_tasks.create!(task_params)
        render json: task_json(t), status: :created
      end

      def update
        t = @lead.lead_tasks.find(params[:id])
        t.update!(task_params)
        render json: task_json(t)
      end

      def destroy
        t = @lead.lead_tasks.find(params[:id])
        t.destroy!
        head :no_content
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [LeadTasksController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [LeadTasksController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [LeadTasksController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [LeadTasksController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_lead
        # STRICT TENANT ISOLATION: Only access leads in same company
        @lead = @company.leads.find(params[:lead_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Lead not found or access denied' }, status: :not_found
        return
      end

      def task_params
        p = params.permit(:title, :dueAt, :done)
        {
          title: p[:title],
          due_at: p[:dueAt],
          done: ActiveModel::Type::Boolean.new.cast(p[:done])
        }.compact
      end

      def task_json(t)
        { id: t.id, title: t.title, dueAt: t.due_at, done: t.done }
      end
    end
  end
end
