# frozen_string_literal: true

# SMS MFA Service - Sends verification codes via SMS using Twilio
# Follows Universal Communication Strategy:
# - Platform Settings → Company Settings → ENV fallback
# - Uses CommunicationSettingsService for configuration
# - Parallel to existing TOTP system (doesn't replace it)

module Mfa
  class SmsService
    attr_reader :user, :company
    
    def initialize(user, company: nil)
      @user = user
      @company = company || user.try(:company)
      @provider = initialize_provider
    end
    
    # Send a new SMS verification code
    # Returns: { success: true/false, message: string }
    def send_code
      unless user.phone.present?
        return failure_result('Phone number is required')
      end
      
      # Generate 6-digit code
      code = sprintf('%06d', SecureRandom.random_number(1_000_000))
      
      # Store code with 5-minute expiration
      user.update!(
        mfa_sms_code: code,
        mfa_sms_expires_at: 5.minutes.from_now
      )
      
      # Send via SMS
      result = @provider.send_message(
        to: user.phone,
        body: sms_body(code)
      )
      
      if result[:success]
        Rails.logger.info "[MFA:SMS] Code sent to #{mask_phone(user.phone)} for user #{user.id}"
        success_result('Code sent successfully')
      else
        Rails.logger.error "[MFA:SMS] Failed to send code to #{mask_phone(user.phone)}: #{result[:error]}"
        failure_result('Failed to send SMS. Please try again.')
      end
    rescue => e
      Rails.logger.error "[MFA:SMS] Error sending code: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      failure_result('SMS service error. Please try again.')
    end
    
    # Verify SMS code
    # Returns: { success: true/false, message: string }
    def verify(code)
      unless user.mfa_sms_code.present?
        return failure_result('No verification code found. Please request a new code.')
      end
      
      if user.mfa_sms_expires_at < Time.current
        user.update!(mfa_sms_code: nil, mfa_sms_expires_at: nil)
        return failure_result('Code expired. Please request a new code.')
      end
      
      if user.mfa_sms_code == code
        # Clear the code and mark phone as verified
        user.update!(
          mfa_sms_code: nil,
          mfa_sms_expires_at: nil,
          phone_verified: true
        )
        
        Rails.logger.info "[MFA:SMS] Code verified for user #{user.id}"
        success_result('Code verified successfully')
      else
        Rails.logger.warn "[MFA:SMS] Invalid code attempt for user #{user.id}"
        failure_result('Invalid code. Please try again.')
      end
    rescue => e
      Rails.logger.error "[MFA:SMS] Error verifying code: #{e.message}"
      failure_result('Verification error. Please try again.')
    end
    
    # Complete MFA enrollment with SMS
    def enable_mfa
      unless user.phone_verified?
        return failure_result('Please verify your phone number first')
      end
      
      user.update!(
        mfa_enabled: true,
        mfa_verified_at: Time.current,
        mfa_method: 'sms'
      )
      
      Rails.logger.info "[MFA:SMS] MFA enabled for user #{user.id}"
      success_result('SMS MFA enabled successfully')
    rescue => e
      Rails.logger.error "[MFA:SMS] Error enabling MFA: #{e.message}"
      failure_result('Failed to enable MFA. Please try again.')
    end
    
    # Disable SMS MFA (keep TOTP data intact)
    def disable_mfa
      user.update!(
        mfa_enabled: false,
        mfa_method: nil,
        phone_verified: false,
        mfa_sms_code: nil,
        mfa_sms_expires_at: nil
        # Keep mfa_secret and mfa_backup_codes for TOTP
      )
      
      Rails.logger.info "[MFA:SMS] MFA disabled for user #{user.id}"
      success_result('SMS MFA disabled successfully')
    rescue => e
      Rails.logger.error "[MFA:SMS] Error disabling MFA: #{e.message}"
      failure_result('Failed to disable MFA. Please try again.')
    end
    
    private
    
    def initialize_provider
      # Use Universal Communication Strategy: Company → Platform → ENV
      settings_service = company ? 
        CommunicationSettingsService.for_company(company) : 
        CommunicationSettingsService.platform
      
      sms_config = settings_service.sms_config
      
      # Initialize Twilio provider
      Providers::Sms::TwilioProvider.new(company: company)
    rescue => e
      Rails.logger.error "[MFA:SMS] Failed to initialize provider: #{e.message}"
      nil
    end
    
    def sms_body(code)
      "Platform DMS: Your verification code is #{code}. Valid for 5 minutes."
    end
    
    def mask_phone(phone)
      return '(hidden)' if phone.blank?
      phone.to_s.gsub(/\d(?=\d{4})/, '*')
    end
    
    def success_result(message)
      { success: true, message: message }
    end
    
    def failure_result(message)
      { success: false, message: message }
    end
  end
end
