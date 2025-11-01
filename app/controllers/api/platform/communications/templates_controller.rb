# frozen_string_literal: true

module Api
  module Platform
    module Communications
      class TemplatesController < ApplicationController
        before_action :set_template, only: [:show, :update, :destroy, :test]
        
        # GET /api/platform/communications/templates
        def index
          templates = CommunicationTemplate.all
          
          # Apply filters
          templates = templates.where(company_id: params[:company_id]) if params[:company_id].present?
          templates = templates.where(template_type: params[:template_type]) if params[:template_type].present?
          templates = templates.where(channel: params[:channel]) if params[:channel].present?
          templates = templates.where(is_active: params[:is_active]) if params[:is_active].present?
          
          render json: {
            success: true,
            templates: templates.map { |t| serialize_template(t) }
          }
        end
        
        # GET /api/platform/communications/templates/:id
        def show
          render json: {
            success: true,
            template: serialize_template(@template)
          }
        end
        
        # POST /api/platform/communications/templates
        def create
          @template = CommunicationTemplate.new(template_params)
          
          if @template.save
            render json: {
              success: true,
              template: serialize_template(@template)
            }, status: :created
          else
            render json: {
              success: false,
              errors: @template.errors.full_messages
            }, status: :unprocessable_entity
          end
        end
        
        # PATCH/PUT /api/platform/communications/templates/:id
        def update
          if @template.update(template_params)
            render json: {
              success: true,
              template: serialize_template(@template)
            }
          else
            render json: {
              success: false,
              errors: @template.errors.full_messages
            }, status: :unprocessable_entity
          end
        end
        
        # DELETE /api/platform/communications/templates/:id
        def destroy
          @template.destroy
          render json: {
            success: true,
            message: 'Template deleted successfully'
          }
        end
        
        # POST /api/platform/communications/templates/:id/test
        def test
          recipient = params[:recipient]
          company_id = params[:company_id] || @template.company_id
          
          unless recipient.present?
            return render json: {
              success: false,
              error: 'Recipient is required'
            }, status: :unprocessable_entity
          end
          
          begin
            # Get communication settings (platform + company override)
            company = company_id ? ::Company.find(company_id) : nil
            settings = get_communication_settings(company, @template.channel)
            
            Rails.logger.info "[TemplatesController#test] Settings: #{settings.inspect}"
            
            # Validate required settings
            if @template.channel == 'email'
              unless settings[:from_email].present? && settings[:from_name].present?
                return render json: {
                  success: false,
                  error: 'Email settings are not configured. Please configure platform email settings first.'
                }, status: :unprocessable_entity
              end
            else # sms
              unless settings[:from_number].present?
                return render json: {
                  success: false,
                  error: 'SMS settings are not configured. Please configure platform SMS settings first.'
                }, status: :unprocessable_entity
              end
            end
            
            # Generate sample context for template rendering
            sample_context = generate_sample_context(@template.template_type)
            
            # Render template
            rendered = @template.render(sample_context)
            
            # Send test message based on channel
            result = if @template.channel == 'email'
              send_test_email(
                to: recipient,
                subject: rendered[:subject] || @template.subject,
                body: rendered[:body],
                from_email: settings[:from_email],
                from_name: settings[:from_name]
              )
            else # sms
              send_test_sms(
                to: recipient,
                body: rendered[:body],
                from_number: settings[:from_number]
              )
            end
            
            if result[:success]
              render json: {
                success: true,
                message: "Test #{@template.channel} sent successfully to #{recipient}"
              }
            else
              render json: {
                success: false,
                error: result[:error] || 'Failed to send test message'
              }, status: :unprocessable_entity
            end
          rescue => e
            Rails.logger.error "[TemplatesController#test] Error: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            render json: {
              success: false,
              error: e.message
            }, status: :internal_server_error
          end
        end
        
        private
        
        def set_template
          @template = CommunicationTemplate.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: {
            success: false,
            error: 'Template not found'
          }, status: :not_found
        end
        
        def template_params
          params.require(:template).permit(
            :name,
            :template_type,
            :channel,
            :subject,
            :body,
            :is_active,
            :is_default,
            :company_id,
            :description
          )
        end
        
        def serialize_template(template)
          {
            id: template.id,
            name: template.name,
            templateType: template.template_type,
            channel: template.channel,
            subject: template.subject,
            body: template.body,
            isActive: template.is_active,
            isDefault: template.is_default,
            companyId: template.company_id,
            description: template.description,
            createdAt: template.created_at,
            updatedAt: template.updated_at
          }
        end
        
        # Get communication settings with platform defaults + company overrides
        def get_communication_settings(company, channel)
          # Start with platform settings
          platform_comms = PlatformSetting.communications || {}
          
          # Get channel-specific settings
          channel_key = channel.to_sym
          platform_settings = platform_comms[channel_key] || {}
          
          # Override with company settings if available
          if company
            company_comms = company.communications_settings
            if company_comms && company_comms[channel]
              company_settings = company_comms[channel].deep_symbolize_keys
              platform_settings = platform_settings.deep_merge(company_settings)
            end
          end
          
          # Convert to consistent format with defaults
          if channel == 'email'
            {
              from_email: platform_settings[:fromEmail] || platform_settings[:from_email] || ENV['EMAIL_FROM'] || 'noreply@renterinsight.com',
              from_name: platform_settings[:fromName] || platform_settings[:from_name] || ENV['EMAIL_FROM_NAME'] || 'RenterInsight',
              provider: platform_settings[:provider] || ENV['EMAIL_PROVIDER'] || 'smtp'
            }
          else # sms
            {
              from_number: platform_settings[:fromNumber] || platform_settings[:from_number] || ENV['SMS_FROM_NUMBER'] || ENV['TWILIO_FROM_NUMBER'],
              provider: platform_settings[:provider] || ENV['SMS_PROVIDER'] || 'twilio'
            }
          end
        end
        
        # Generate sample context data based on template type
        def generate_sample_context(template_type)
          case template_type
          when 'company_user_invitation'
            {
              user_name: 'John Doe',
              user_email: 'john.doe@example.com',
              company_name: 'Demo Company',
              role_name: 'Admin',
              login_url: 'https://app.example.com/login',
              admin_email: 'admin@example.com',
              admin_name: 'System Administrator',
              setup_instructions: 'Click the link above to set your password and access your account.'
            }
          when 'password_reset'
            {
              user_name: 'John Doe',
              reset_url: 'https://app.example.com/reset-password/token123',
              expiry_time: '1 hour'
            }
          when 'quote'
            {
              customer_name: 'Jane Smith',
              quote_number: 'Q-12345',
              quote_total: '$1,234.56',
              company_name: 'Demo Company'
            }
          else
            # Generic sample data
            {
              name: 'John Doe',
              company_name: 'Demo Company',
              date: Time.current.strftime('%B %d, %Y'),
              message: 'This is a test message'
            }
          end
        end
        
        # Send test email using CommunicationMailer
        def send_test_email(to:, subject:, body:, from_email:, from_name:)
          begin
            CommunicationMailer.send_communication(
              to: to,
              subject: "[TEST] #{subject}",
              body: body,
              from_email: from_email,
              from_name: from_name
            ).deliver_now
            
            { success: true }
          rescue => e
            Rails.logger.error "[TemplatesController] Email send failed: #{e.message}"
            { success: false, error: e.message }
          end
        end
        
        # Send test SMS using Twilio provider
        def send_test_sms(to:, body:, from_number:)
          begin
            # Use Twilio provider directly
            provider = Providers::Sms::TwilioProvider.new(company: nil)
            result = provider.send_message(
              to: to,
              from: from_number,
              body: "[TEST] #{body}"
            )
            
            { success: true, external_id: result[:external_id] }
          rescue => e
            Rails.logger.error "[TemplatesController] SMS send failed: #{e.message}"
            { success: false, error: e.message }
          end
        end
      end
    end
  end
end
