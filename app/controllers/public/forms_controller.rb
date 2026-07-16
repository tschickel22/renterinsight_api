module Public
  class FormsController < ApplicationController
    # Skip authentication for public forms
    skip_before_action :authenticate_user!, raise: false
    skip_before_action :authenticate, raise: false
    
    before_action :set_form
    
    def show
      response = @form.as_json

      # Include the company's active locations so the public form can offer
      # a "which location is closest to you?" picker when the admin left the
      # form's location_id unset. Hidden when the form is already bound to
      # a specific location (admin's choice wins — no need to ask the visitor)
      # or when the company has a single location (nothing to pick).
      if @form.location_id.blank?
        locations = @form.company.locations.active.order(:name)
        if locations.count > 1
          response['company_locations'] = locations.map do |l|
            { id: l.id, name: l.name, city: l.city, state: l.state }
          end
        end
      end

      render json: response
    end
    
    def submit
      Rails.logger.info "Form submission received for public_id: #{params[:public_id]}"

      # Parse the JSON body
      data = JSON.parse(request.body.read) rescue {}
      Rails.logger.info "Parsed submission data: #{data.inspect}"

      # CAPTCHA gate — pulled out of the submission data so it never lands in
      # the stored lead record. Fails closed if the form requires it and the
      # token is missing or invalid.
      if @form.captcha_required
        token = data.delete('captcha_token') || data.delete('captchaToken')
        unless TurnstileVerifier.verify(token, remote_ip: request.remote_ip)
          Rails.logger.warn "[Public::FormsController] Turnstile verification failed for form #{@form.id}"
          render json: { success: false, error: 'CAPTCHA verification failed. Please try again.' }, status: :forbidden and return
        end
      end

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
