module Api
  module Crm
    module Intake
      class SubmissionsController < ApplicationController
        include RbacAuthorization
        rbac_resource :crm,
          read_actions: [:index],
          create_actions: [],
          update_actions: [],
          delete_actions: []

        # Public endpoints for external form submissions
        skip_before_action :authenticate, only: [:create, :bulk]
        before_action :set_company_scope, only: [:index]
        
        def index
          # Get submissions through company's forms only
          submissions = IntakeSubmission
            .joins(:intake_form)
            .where(intake_forms: { company_id: @company.id })
            .includes(:intake_form, :lead)
            .order(created_at: :desc)
            .limit(100)
          
          render json: submissions.map { |s| submission_json(s) }
        end
        
        # Public endpoint - form submissions from external sites
        def create
          @form = IntakeForm.find_by(id: submission_params[:intake_form_id], is_active: true)
          
          unless @form
            render json: { 
              success: false,
              error: 'Form not found or inactive' 
            }, status: :not_found
            return
          end
          
          @submission = @form.intake_submissions.build(
            payload: submission_params[:payload] || submission_params.except(:intake_form_id),
            ip_address: request.remote_ip,
            user_agent: request.user_agent,
            referrer: request.referer
          )
          
          if @submission.save
            render json: { 
              success: true,
              submission: @submission,
              lead: @submission.lead,
              message: @form.thank_you_message || 'Thank you for your submission!'
            }, status: :created
          else
            render json: { 
              success: false,
              errors: @submission.errors.full_messages 
            }, status: :unprocessable_entity
          end
        end

        # Public endpoint - bulk form submissions
        def bulk
          submissions_data = params[:_json] || [params]
          results = []
          errors = []
          
          submissions_data.each do |sub_data|
            form_id = sub_data[:formId] || sub_data[:intake_form_id]
            form = IntakeForm.find_by(id: form_id, is_active: true)
            
            unless form
              errors << { form_id: form_id, error: 'Form not found or inactive' }
              next
            end
            
            submission = form.intake_submissions.create(
              payload: sub_data.except(:formId, :intake_form_id),
              ip_address: request.remote_ip,
              user_agent: request.user_agent,
              referrer: request.referer
            )
            
            if submission.persisted?
              results << {
                submission: submission,
                lead: submission.lead
              }
            else
              errors << { 
                form_id: form_id, 
                errors: submission.errors.full_messages 
              }
            end
          end
          
          if errors.any?
            render json: { 
              success: false,
              submissions: results, 
              errors: errors 
            }, status: :unprocessable_entity
          else
            render json: { 
              success: true,
              submissions: results 
            }
          end
        end

        private
        
        def set_company_scope
          unless current_user
            Rails.logger.error "🚫 [Intake::SubmissionsController] No authenticated user found"
            render json: { error: 'Authentication required' }, status: :unauthorized
            return
          end
          
          company_id = current_company_id
          
          unless company_id.present?
            Rails.logger.error "🚫 [Intake::SubmissionsController] No company context available"
            render json: { error: 'No company context' }, status: :forbidden
            return
          end
          
          @company = ::Company.find_by(id: company_id)
          
          if @company.nil?
            Rails.logger.error "🚫 [Intake::SubmissionsController] Company #{company_id} not found"
            render json: { error: 'Company not found' }, status: :not_found
            return
          end
          
          Rails.logger.info "✅ [Intake::SubmissionsController] Company scope set: #{@company.name} (ID: #{@company.id})"
        end

        def submission_params
          params.permit(:intake_form_id, :formId, payload: {}).tap do |p|
            if params[:payload].blank? && params.except(:intake_form_id, :formId, :controller, :action).any?
              p[:payload] = params.except(:intake_form_id, :formId, :controller, :action)
            end
          end
        end

        def submission_json(submission)
          {
            id: submission.id,
            intakeFormId: submission.intake_form_id,
            formName: submission.intake_form&.name,
            payload: submission.payload,
            ipAddress: submission.ip_address,
            userAgent: submission.user_agent,
            referrer: submission.referrer,
            leadId: submission.lead_id,
            lead: submission.lead ? {
              id: submission.lead.id,
              firstName: submission.lead.first_name,
              lastName: submission.lead.last_name,
              email: submission.lead.email
            } : nil,
            createdAt: submission.created_at&.iso8601,
            updatedAt: submission.updated_at&.iso8601
          }
        end
      end
    end
  end
end
