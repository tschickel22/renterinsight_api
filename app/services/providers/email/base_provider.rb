# frozen_string_literal: true

module Providers
  module Email
    class BaseProvider
      attr_reader :company, :location, :user, :config
      
      def initialize(company: nil, location: nil, user: nil)
        @company = company
        @location = location
        @user = user
        @config = load_config
      end
      
      def send_message(to:, from:, subject:, body:, **options)
        raise NotImplementedError, "#{self.class.name} must implement send_message"
      end
      
      protected
      
      def load_config
        # Waterfall priority: User → Location → Company → Platform
        # Check if user has their own email connection configured
        if user&.has_email_connection?
          Rails.logger.info "[BaseProvider] Loading email config from user #{user.id} connection"
          return CommunicationSettingsService.for_user(user).email_config
        end
        
        settings_service = company ? 
          CommunicationSettingsService.for_company(company, location: location) : 
          CommunicationSettingsService.platform
        
        settings_service.email_config
      end
      
      def validate_config!
        raise ConfigurationError, "From email is required" if config[:from_email].blank?
      end
      
      class ConfigurationError < StandardError; end
      class DeliveryError < StandardError; end
    end
  end
end
