module Api
  module Crm
    module Nurture
      class StepsController < ApplicationController
        include RbacAuthorization
        rbac_resource :crm

        before_action :set_company_scope
        before_action :load_sequence

        # GET /api/crm/nurture/sequences/:sequence_id/steps
        def index
          render json: @sequence.nurture_steps.order(:position).map { |s| step_json(s) }
        end

        # GET /api/crm/nurture/sequences/:sequence_id/steps/:id
        def show
          step = @sequence.nurture_steps.find_by(id: params[:id])
          unless step
            render json: { error: 'Step not found' }, status: :not_found
            return
          end
          render json: step_json(step)
        end

        # POST /api/crm/nurture/sequences/:sequence_id/steps
        def create
          step = @sequence.nurture_steps.build(step_params)
          if step.save
            render json: step_json(step), status: :created
          else
            render json: { errors: step.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH/PUT /api/crm/nurture/sequences/:sequence_id/steps/:id
        def update
          step = @sequence.nurture_steps.find_by(id: params[:id])
          unless step
            render json: { error: 'Step not found' }, status: :not_found
            return
          end
          
          if step.update(step_params)
            render json: step_json(step)
          else
            render json: { errors: step.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/crm/nurture/sequences/:sequence_id/steps/:id
        def destroy
          step = @sequence.nurture_steps.find_by(id: params[:id])
          unless step
            render json: { error: 'Step not found' }, status: :not_found
            return
          end
          
          step.destroy
          head :no_content
        end

        private

        def set_company_scope
          unless current_user
            Rails.logger.error "🚫 [Nurture::StepsController] No authenticated user found"
            render json: { error: 'Authentication required' }, status: :unauthorized
            return
          end
          
          company_id = current_company_id
          
          unless company_id.present?
            Rails.logger.error "🚫 [Nurture::StepsController] No company context available"
            render json: { error: 'No company context' }, status: :forbidden
            return
          end
          
          @company = ::Company.find_by(id: company_id)
          
          if @company.nil?
            Rails.logger.error "🚫 [Nurture::StepsController] Company #{company_id} not found"
            render json: { error: 'Company not found' }, status: :not_found
            return
          end
          
          Rails.logger.info "✅ [Nurture::StepsController] Company scope set: #{@company.name} (ID: #{@company.id})"
        end

        def load_sequence
          @sequence = @company.nurture_sequences.find_by(id: params[:sequence_id])
          unless @sequence
            render json: { error: 'Sequence not found or access denied' }, status: :not_found
            return
          end
        end

        def step_params
          params.require(:step).permit(:position, :step_type, :subject, :body, :wait_hours, :wait_days, :template_id)
        end

        def step_json(step)
          {
            id: step.id,
            step_type: step.step_type || 'email',
            type: step.step_type || 'email',
            subject: step.subject || '',
            body: step.body || '',
            wait_days: step.wait_days || 0,
            waitDays: step.wait_days || 0,
            position: step.position || 0,
            order: step.position || 0,
            template_id: step.template_id,
            templateId: step.template_id,
            nurture_sequence_id: step.nurture_sequence_id,
            nurtureSequenceId: step.nurture_sequence_id,
            createdAt: step.created_at&.iso8601,
            updatedAt: step.updated_at&.iso8601
          }
        end
      end
    end
  end
end
