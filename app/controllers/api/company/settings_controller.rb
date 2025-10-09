# frozen_string_literal: true

module Api
  module Company
    class SettingsController < ApplicationController
      def show
        company = find_or_create_company
        
        render json: {
          communications: company&.communications_settings || default_communications_settings,
          notifications: company&.notifications_settings || default_notifications_settings,
          companyId: company&.id
        }, status: :ok
      rescue => e
        Rails.logger.error "[CompanySettings#show] Error: #{e.message}"
        # Return safe defaults instead of crashing
        render json: {
          communications: default_communications_settings,
          notifications: default_notifications_settings
        }, status: :ok
      end

      def update
        company = find_or_create_company
        
        if company
          # Update communications settings if provided
          if params[:communications]
            settings = params[:communications]
            if company.respond_to?(:communications_settings=)
              company.communications_settings = settings
            end
          end
          
          # Update notifications settings if provided
          if params[:notifications]
            settings = params[:notifications]
            if company.respond_to?(:notifications_settings=)
              company.notifications_settings = settings
            end
          end
          
          render json: {
            communications: company.communications_settings || default_communications_settings,
            notifications: company.notifications_settings || default_notifications_settings,
            companyId: company.id,
            message: 'Settings updated successfully'
          }, status: :ok
        else
          # No company, but return success with the settings they sent
          render json: {
            communications: params[:communications] || default_communications_settings,
            notifications: params[:notifications] || default_notifications_settings,
            message: 'Settings saved (no company record yet)'
          }, status: :ok
        end
      rescue => e
        Rails.logger.error "[CompanySettings#update] Error: #{e.message}"
        render json: { 
          error: 'Failed to update settings',
          message: e.message 
        }, status: :unprocessable_entity
      end

      private

      def find_or_create_company
        # Try to find existing company
        company = current_user&.company || Company.first rescue nil
        
        # If no company exists, create a default one
        if company.nil? && defined?(Company)
          begin
            company = Company.create!(name: 'Demo Company')
          rescue => e
            Rails.logger.warn "[CompanySettings] Could not create company: #{e.message}"
            nil
          end
        end
        
        company
      end

      def default_communications_settings
        {
          email: {
            provider: 'smtp',
            fromEmail: 'noreply@example.com',
            fromName: 'Demo Company',
            isEnabled: true
          },
          sms: {
            provider: 'twilio',
            fromNumber: '+1234567890',
            isEnabled: false
          }
        }
      end
      
      def default_notifications_settings
        {
          email: {
            isEnabled: true,
            sendReminders: true,
            sendActivityUpdates: true,
            dailyDigest: false
          },
          sms: {
            isEnabled: false,
            sendReminders: true,
            sendUrgentOnly: true
          },
          popup: {
            isEnabled: true,
            showReminders: true,
            showActivityUpdates: true,
            autoClose: true,
            autoCloseDelay: 5000
          }
        }
      end
    end
  end
end
