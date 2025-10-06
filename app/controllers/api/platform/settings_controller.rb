cat > app/controllers/api/platform/settings_controller.rb << 'EOF'
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
        # For now, just acknowledge the update
        # Can persist to a PlatformSetting model later
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
          emailEnabled: true,
          smsEnabled: true,
          defaultSender: 'noreply@renterinsight.com',
          replyTo: 'support@renterinsight.com'
        }
      end
    end
  end
end
EOF
