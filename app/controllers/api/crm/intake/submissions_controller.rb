module Api
  module Crm
    module Intake
      class SubmissionsController < ApplicationController
        skip_before_action :authenticate, only: [:create, :bulk]
        before_action :set_company, only: [:index]
        
        def index
          @submissions = @company.intake_forms
            .joins(:intake_submissions)
            .merge(IntakeSubmission.recent)
            .limit(100)
          
          render json: @submissions.as_json(
            include: {
              intake_form: { only: [:id, :name] },
              lead: { only: [:id, :first_name, :last_name, :email] }
            }
          )
        end
        
        def create
          @form = IntakeForm.find_by!(id: submission_params[:intake_form_id], is_active: true)
          
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
        rescue ActiveRecord::RecordNotFound
          render json: { 
            success: false,
            error: 'Form not found or inactive' 
          }, status: :not_found
        end

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
        
        def set_company
          @company = Company.find(current_company_id)
        rescue ActiveRecord::RecordNotFound
          render json: { error: 'Company not found' }, status: :not_found
        end

        def submission_params
          params.permit(:intake_form_id, :formId, payload: {}).tap do |p|
            if params[:payload].blank? && params.except(:intake_form_id, :formId, :controller, :action).any?
              p[:payload] = params.except(:intake_form_id, :formId, :controller, :action)
            end
          end
        end
      end
    end
  end
end
