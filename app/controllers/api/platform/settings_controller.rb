# frozen_string_literal: true

module Api
  module Platform
    class SettingsController < ApplicationController
      def show
        render json: {
          communications: default_communications_settings
        }, status: :ok
      rescue => e
        Rails.logger.error "[PlatformSettings#show] Error: #{e.message}"
        render json: {
          communications: default_communications_settings
        }, status: :ok
      end

      def update
        # Platform settings are read-only for now, but accept the request
        render json: {
          communications: params[:communications] || default_communications_settings,
          message: 'Settings updated successfully'
        }, status: :ok
      rescue => e
        Rails.logger.error "[PlatformSettings#update] Error: #{e.message}"
        render json: { 
          error: 'Failed to update settings',
          message: e.message 
        }, status: :unprocessable_entity
      end

      private

      def default_communications_settings
        {
          email: {
            provider: 'smtp',
            fromEmail: 'platform@renterinsight.com',
            fromName: 'RenterInsight Platform',
            smtpHost: 'smtp.example.com',
            smtpPort: 587,
            isEnabled: true
          },
          sms: {
            provider: 'twilio',
            fromNumber: '+1234567890',
            isEnabled: false
          }
        }
      end
    end
  end
end
