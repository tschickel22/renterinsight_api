# Base provider interface that all communication providers must implement
# Ensures consistent interface across email, SMS, and other channels

module Providers
  class BaseProvider
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class SendError < Error; end
    
    # Must be implemented by subclasses
    def send_message(**args)
      raise NotImplementedError, "#{self.class.name} must implement #send_message"
    end
    
    # Optional: Verify provider configuration
    def verify_configuration
      raise NotImplementedError, "#{self.class.name} must implement #verify_configuration"
    end
    
    # Optional: Get delivery status
    def get_delivery_status(external_id)
      raise NotImplementedError, "#{self.class.name} does not support delivery status"
    end
    
    # Optional: Handle webhook callbacks
    def handle_webhook(payload)
      raise NotImplementedError, "#{self.class.name} does not support webhooks"
    end
    
    protected
    
    # Helper to validate required configuration
    def require_config(*keys)
      missing = keys.select { |key| config[key].blank? }
      
      if missing.any?
        raise ConfigurationError, 
          "Missing required configuration: #{missing.join(', ')}"
      end
    end
    
    # Get configuration from environment or settings
    def config
      @config ||= {}
    end
    
    # Log provider activity
    def log_info(message)
      Rails.logger.info("[#{self.class.name}] #{message}")
    end
    
    def log_error(message)
      Rails.logger.error("[#{self.class.name}] #{message}")
    end
    
    # Format result consistently
    def success_result(external_id: nil, details: {})
      {
        success: true,
        external_id: external_id,
        provider: self.class.name.demodulize.underscore,
        sent_at: Time.current,
        details: details
      }
    end
    
    def error_result(error, details: {})
      {
        success: false,
        error: error.message,
        provider: self.class.name.demodulize.underscore,
        details: details
      }
    end
  end
end
