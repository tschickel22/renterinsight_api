# frozen_string_literal: true

module Providers
  module Email
    class BaseProvider
      attr_reader :company, :config
      
      def initialize(company: nil)
        @company = company
        @config = load_config
      end
      
      def send_message(to:, from:, subject:, body:, **options)
        raise NotImplementedError, "#{self.class.name} must implement send_message"
      end
      
      protected
      
      def load_config
        settings_service = company ? 
          CommunicationSettingsService.for_company(company) : 
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
