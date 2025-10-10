module Public
  class FormsController < ApplicationController
    # Skip authentication for public forms
    skip_before_action :authenticate_user!, raise: false
    skip_before_action :authenticate, raise: false
    
    before_action :set_form
    
    def show
      render json: @form.as_json
    end
    
    def submit
      Rails.logger.info "Form submission received for public_id: #{params[:public_id]}"
      
      # Parse the JSON body
      data = JSON.parse(request.body.read) rescue {}
      Rails.logger.info "Parsed submission data: #{data.inspect}"
      
      submission = @form.intake_submissions.build(
        data: data,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        referrer: request.referrer,
        submitted_at: Time.current
      )
      
      if submission.save
        Rails.logger.info "Submission saved with ID: #{submission.id}"
        Rails.logger.info "Lead created: #{submission.lead_created}, Lead ID: #{submission.lead_id}"
        
        # Force lead creation if it didn't happen automatically
        if !submission.lead_created && !submission.lead_id
          Rails.logger.info "Attempting manual lead creation..."
          lead = submission.create_lead_from_submission
          Rails.logger.info "Manual lead creation result: #{lead ? "Lead ID #{lead.id}" : "Failed"}"
          submission.reload
        end
        
        render json: { 
          success: true, 
          message: @form.thank_you_message || 'Thank you for your submission!',
          redirect_url: @form.redirect_url,
          lead_created: submission.lead_created,
          submission_id: submission.id
        }
      else
        Rails.logger.error "Submission failed: #{submission.errors.full_messages}"
        render json: { 
          success: false,
          errors: submission.errors.full_messages 
        }, status: :unprocessable_entity
      end
    rescue => e
      Rails.logger.error "Error processing submission: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { success: false, error: 'Internal server error' }, status: :internal_server_error
    end
    
    private
    
    def set_form
      @form = IntakeForm.active.find_by!(public_id: params[:public_id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Form not found or inactive' }, status: :not_found
    end
  end
end
