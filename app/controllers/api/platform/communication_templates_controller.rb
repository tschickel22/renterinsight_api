# frozen_string_literal: true

module Api
  module Platform
    class CommunicationTemplatesController < ApplicationController
      before_action :set_template, only: [:show, :update, :destroy, :send_test]
      
      # GET /api/platform/communications/templates
      def index
        templates = CommunicationTemplate.all
        
        # Apply filters
        templates = templates.by_type(params[:template_type]) if params[:template_type].present?
        templates = templates.for_channel(params[:channel]) if params[:channel].present?
        templates = templates.active if params[:is_active] == 'true'
        
        # Include both Platform templates and Company-specific templates
        if params[:company_id].present?
          templates = templates.where(
            "scope_type = 'Platform' OR (scope_type = 'Company' AND scope_id = ?)",
            params[:company_id]
          )
        end
        
        templates = templates.order(created_at: :desc)
        
        render json: {
          success: true,
          templates: templates.map { |t| template_json(t) }
        }, status: :ok
      end
      
      # GET /api/platform/communications/templates/:id
      def show
        render json: {
          success: true,
          template: template_json(@template)
        }, status: :ok
      end
      
      # POST /api/platform/communications/templates
      def create
        template = CommunicationTemplate.new(template_create_params)
        
        if template.save
          render json: {
            success: true,
            template: template_json(template),
            message: 'Template created successfully'
          }, status: :created
        else
          render json: {
            success: false,
            errors: template.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # PATCH/PUT /api/platform/communications/templates/:id
      def update
        if @template.update(template_update_params)
          render json: {
            success: true,
            template: template_json(@template),
            message: 'Template updated successfully'
          }, status: :ok
        else
          render json: {
            success: false,
            errors: @template.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/platform/communications/templates/:id
      def destroy
        @template.destroy!
        render json: {
          success: true,
          message: 'Template deleted successfully'
        }, status: :ok
      rescue => e
        render json: {
          success: false,
          error: e.message
        }, status: :unprocessable_entity
      end
      
      # POST /api/platform/communications/templates/:id/test
      def send_test
        recipient = params[:recipient]
        
        unless recipient.present?
          return render json: {
            success: false,
            error: 'Recipient is required'
          }, status: :bad_request
        end
        
        # Build sample context for rendering
        context = build_test_context(recipient)
        
        # Render the template
        rendered = @template.render(context)
        
        begin
          # Send test directly without creating Communication record
          if @template.channel == 'email'
            result = send_test_email(recipient, rendered[:subject], rendered[:body])
          elsif @template.channel == 'sms'
            result = send_test_sms(recipient, rendered[:body])
          else
            return render json: {
              success: false,
              error: "Unsupported channel: #{@template.channel}"
            }, status: :bad_request
          end
          
          if result[:success]
            render json: {
              success: true,
              message: "Test #{@template.channel} sent successfully to #{recipient}"
            }, status: :ok
          else
            render json: {
              success: false,
              error: result[:error] || 'Failed to send test'
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error("Test send failed: #{e.message}")
          Rails.logger.error(e.backtrace.first(5).join("\n"))
          
          render json: {
            success: false,
            error: "Failed to send test: #{e.message}"
          }, status: :internal_server_error
        end
      end
      
      private
      
      def set_template
        @template = CommunicationTemplate.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { success: false, error: 'Template not found' }, status: :not_found
      end
      
      def template_create_params
        {
          name: params[:name],
          channel: params[:channel],
          template_type: params[:templateType] || params[:template_type],
          subject_template: params[:subject],
          body_template: params[:body],
          active: params[:isActive].nil? ? true : params[:isActive],
          is_default: params[:isDefault] || false,
          scope_type: params[:companyId] ? 'Company' : 'Platform',
          scope_id: params[:companyId]
        }
      end
      
      def template_update_params
        updates = {}
        updates[:name] = params[:name] if params[:name].present?
        updates[:subject_template] = params[:subject] if params.key?(:subject)
        updates[:body_template] = params[:body] if params[:body].present?
        updates[:active] = params[:isActive] if params.key?(:isActive)
        updates[:is_default] = params[:isDefault] if params.key?(:isDefault)
        updates
      end
      
      def template_json(template)
        {
          id: template.id,
          companyId: template.scope_type == 'Company' ? template.scope_id : nil,
          templateType: template.template_type,
          name: template.name,
          channel: template.channel,
          subject: template.subject_template,
          body: template.body_template,
          variables: template.available_variables,
          isActive: template.active,
          isDefault: template.is_default || false,
          createdAt: template.created_at&.iso8601,
          updatedAt: template.updated_at&.iso8601
        }
      end
      
      def build_test_context(recipient)
        # Get company name from current user or use default
        company_name = current_user&.company&.name || 'Demo Company'
        
        # Build sample context with all common variables
        {
          'user_name' => 'Test User',
          'recipient_name' => 'Test User',
          'company_name' => company_name,
          'login_url' => "#{ENV['FRONTEND_URL'] || 'https://localhost:5173'}/invitations/company-user?token=TEST_TOKEN_123",
          'invitation_url' => "#{ENV['FRONTEND_URL'] || 'https://localhost:5173'}/invitations/company-user?token=TEST_TOKEN_123",
          'invitation_expires' => (Time.current + 7.days).strftime('%B %d, %Y at %I:%M %p'),
          'expires_at' => (Time.current + 7.days).strftime('%B %d, %Y at %I:%M %p'),
          'admin_name' => current_user&.name || 'Admin User',
          'admin_email' => current_user&.email || 'admin@company.com',
          'inviter_name' => current_user&.name || 'Admin User',
          'role_name' => 'Staff Member',
          'role' => 'Staff Member',
          'setup_instructions' => 'Click the login link and follow the prompts to set up your password.',
          'message' => 'Welcome to the team! We\'re excited to have you.',
          'invitation_code' => 'TEST123'
        }
      end
      
      # Send test email directly using provider
      def send_test_email(to, subject, body)
        # Get platform settings
        settings_service = CommunicationSettingsService.platform
        email_config = settings_service.email_config
        
        # Determine provider from settings
        provider = email_config[:provider]&.to_sym || :smtp
        
        # Get provider class
        provider_class = case provider
                         when :smtp
                           Providers::Email::SmtpProvider
                         when :gmail_relay
                           Providers::Email::GmailRelayProvider
                         when :aws_ses
                           Providers::Email::AwsSesProvider
                         else
                           Providers::Email::SmtpProvider
                         end
        
        # Send email
        provider_instance = provider_class.new(company: nil)
        provider_instance.send_message(
          to: to,
          from: email_config[:from_email],
          subject: subject,
          body: body,
          metadata: { test: true, template_id: @template.id }
        )
      rescue => e
        Rails.logger.error("Test email send failed: #{e.message}")
        { success: false, error: e.message }
      end
      
      # Send test SMS directly using provider
      def send_test_sms(to, body)
        # Get platform settings
        settings_service = CommunicationSettingsService.platform
        sms_config = settings_service.sms_config
        
        # Send SMS via Twilio
        provider_instance = Providers::Sms::TwilioProvider.new(company: nil)
        provider_instance.send_message(
          to: to,
          from: sms_config[:from_number],
          body: body,
          metadata: { test: true, template_id: @template.id }
        )
      rescue => e
        Rails.logger.error("Test SMS send failed: #{e.message}")
        { success: false, error: e.message }
      end
    end
  end
end
