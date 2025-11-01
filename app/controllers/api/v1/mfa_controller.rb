# frozen_string_literal: true

module Api
  module V1
    class MfaController < ApplicationController
      before_action :authenticate_user!
      
      # GET /api/v1/mfa/status
      # Returns current MFA status for the user (supports both TOTP and SMS)
      def status
        render json: {
          mfa_enabled: current_user.mfa_enabled?,
          mfa_method: current_user.mfa_method,
          mfa_verified_at: current_user.mfa_verified_at,
          phone: current_user.phone,
          phone_verified: current_user.phone_verified?,
          backup_codes_count: current_user.mfa_backup_codes&.length || 0,
          backup_codes_low: (current_user.mfa_backup_codes&.length || 0) < 3
        }
      end
      
      # POST /api/v1/mfa/enroll
      # Initiates MFA enrollment by generating a secret and QR code
      def enroll
        # Don't allow re-enrollment if already enabled
        if current_user.mfa_enabled?
          return render json: { error: 'MFA is already enabled' }, status: :unprocessable_entity
        end
        
        # Generate new secret (32 chars = 160 bits)
        secret = ROTP::Base32.random
        
        # Debug logging
        Rails.logger.info "=== MFA ENROLL DEBUG ==="
        Rails.logger.info "Generated secret: #{secret}"
        Rails.logger.info "Secret length: #{secret.length}"
        Rails.logger.info "User email: #{current_user.email}"
        
        # Store secret temporarily (not verified yet)
        current_user.update!(mfa_secret: secret)
        
        # Verify it was saved
        Rails.logger.info "Saved secret: #{current_user.reload.mfa_secret}"
        Rails.logger.info "Secrets match: #{current_user.mfa_secret == secret}"
        
        # Generate QR code URL for authenticator apps
        totp = ROTP::TOTP.new(secret, issuer: 'Platform DMS')
        qr_code_url = totp.provisioning_uri(current_user.email)
        
        Rails.logger.info "QR Code URL: #{qr_code_url}"
        Rails.logger.info "Current code: #{totp.now}"
        Rails.logger.info "========================"
        
        render json: {
          secret: secret,
          qr_code_url: qr_code_url
        }
      end
      
      # POST /api/v1/mfa/verify
      # Verifies the TOTP code and completes enrollment
      def verify
        code = params[:code]
        
        unless code.present?
          return render json: { error: 'Verification code is required' }, status: :unprocessable_entity
        end
        
        # Debug logging
        Rails.logger.info "=== MFA VERIFY DEBUG ==="
        Rails.logger.info "Code received: #{code}"
        Rails.logger.info "Secret: #{current_user.mfa_secret}"
        Rails.logger.info "User email: #{current_user.email}"
        
        # Verify the code
        totp = ROTP::TOTP.new(current_user.mfa_secret)
        
        # Get current valid code for debugging
        current_valid_code = totp.now
        Rails.logger.info "Current valid code: #{current_valid_code}"
        Rails.logger.info "Server time: #{Time.current}"
        
        verification_result = totp.verify(code, drift_behind: 30, drift_ahead: 30)
        Rails.logger.info "Verification result: #{verification_result}"
        Rails.logger.info "========================"
        
        unless verification_result
          return render json: { 
            error: 'Invalid verification code',
            debug: Rails.env.development? ? {
              received: code,
              expected: current_valid_code,
              server_time: Time.current.iso8601
            } : nil
          }, status: :unprocessable_entity
        end
        
        Rails.logger.info "Code verified! Enabling MFA and generating backup codes..."
        
        # Enable MFA immediately
        current_user.update!(
          mfa_enabled: true,
          mfa_verified_at: Time.current
        )
        
        # Generate and hash backup codes (this is slow but happens AFTER verification succeeds)
        backup_codes = generate_backup_codes
        hashed_codes = backup_codes.map { |code| BCrypt::Password.create(code) }
        
        current_user.update!(mfa_backup_codes: hashed_codes)
        
        Rails.logger.info "MFA enabled successfully with #{backup_codes.length} backup codes"
        Rails.logger.info "========================"
        
        render json: {
          message: 'MFA enabled successfully',
          backup_codes: backup_codes
        }
      end
      
      # POST /api/v1/mfa/disable
      # Disables MFA (requires verification)
      def disable
        code = params[:code]
        
        unless code.present?
          return render json: { error: 'Verification code is required' }, status: :unprocessable_entity
        end
        
        unless current_user.mfa_enabled?
          return render json: { error: 'MFA is not enabled' }, status: :unprocessable_entity
        end
        
        # Verify with TOTP code or backup code
        unless verify_mfa_code(code)
          return render json: { error: 'Invalid verification code' }, status: :unauthorized
        end
        
        # Disable MFA and clear secrets
        current_user.update!(
          mfa_enabled: false,
          mfa_secret: nil,
          mfa_backup_codes: [],
          mfa_verified_at: nil
        )
        
        render json: { message: 'MFA disabled successfully' }
      end
      
      # POST /api/v1/mfa/backup_codes/regenerate
      # Regenerates backup codes (requires verification)
      def regenerate_backup_codes
        code = params[:code]
        
        unless code.present?
          return render json: { error: 'Verification code is required' }, status: :unprocessable_entity
        end
        
        unless current_user.mfa_enabled?
          return render json: { error: 'MFA is not enabled' }, status: :unprocessable_entity
        end
        
        # Verify with TOTP code (not backup code, since we're regenerating them)
        totp = ROTP::TOTP.new(current_user.mfa_secret)
        unless totp.verify(code, drift_behind: 30, drift_ahead: 30)
          return render json: { error: 'Invalid verification code' }, status: :unauthorized
        end
        
        # Generate new backup codes
        backup_codes = generate_backup_codes
        hashed_codes = backup_codes.map { |code| BCrypt::Password.create(code) }
        
        current_user.update!(mfa_backup_codes: hashed_codes)
        
        render json: {
          message: 'Backup codes regenerated successfully',
          backup_codes: backup_codes
        }
      end
      
      # ============================================================================
      # SMS MFA ENDPOINTS (Parallel to TOTP - Keep TOTP methods above!)
      # ============================================================================
      
      # POST /api/v1/mfa/sms/enroll
      # Initiates SMS MFA enrollment by sending a verification code
      def sms_enroll
        phone = params[:phone_number]
        
        if phone.blank?
          return render json: { error: 'Phone number is required' }, status: :unprocessable_entity
        end
        
        if current_user.mfa_enabled?
          return render json: { error: 'MFA is already enabled' }, status: :unprocessable_entity
        end
        
        # Update phone number
        current_user.update!(phone: phone)
        
        # Send SMS code
        sms_service = Mfa::SmsService.new(current_user)
        result = sms_service.send_code
        
        if result[:success]
          render json: { message: result[:message] }
        else
          render json: { error: result[:message] }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/mfa/sms/verify
      # Verifies SMS code and enables MFA
      def sms_verify
        code = params[:code]
        
        unless code.present?
          return render json: { error: 'Verification code is required' }, status: :unprocessable_entity
        end
        
        sms_service = Mfa::SmsService.new(current_user)
        verify_result = sms_service.verify(code)
        
        if verify_result[:success]
          # Enable MFA with SMS method
          enable_result = sms_service.enable_mfa
          
          if enable_result[:success]
            render json: { 
              message: 'SMS MFA enabled successfully',
              mfa_enabled: true,
              mfa_method: 'sms'
            }
          else
            render json: { error: enable_result[:message] }, status: :unprocessable_entity
          end
        else
          render json: { error: verify_result[:message] }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/mfa/sms/resend
      # Resends SMS verification code
      def sms_resend
        sms_service = Mfa::SmsService.new(current_user)
        result = sms_service.send_code
        
        if result[:success]
          render json: { message: result[:message] }
        else
          render json: { error: result[:message] }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/mfa/sms/disable
      # Disables SMS MFA (keeps TOTP data intact)
      def sms_disable
        unless current_user.mfa_enabled? && current_user.mfa_method == 'sms'
          return render json: { error: 'SMS MFA is not enabled' }, status: :unprocessable_entity
        end
        
        sms_service = Mfa::SmsService.new(current_user)
        result = sms_service.disable_mfa
        
        if result[:success]
          render json: { message: result[:message] }
        else
          render json: { error: result[:message] }, status: :unprocessable_entity
        end
      end
      
      private
      
      def authenticate_user!
        token = request.headers['Authorization']&.gsub('Bearer ', '')
        
        unless token
          return render json: { error: 'Missing authorization token' }, status: :unauthorized
        end
        
        begin
          decoded = JWT.decode(token, Rails.application.secret_key_base, true, algorithm: 'HS256')
          user_id = decoded[0]['user_id']
          @current_user = User.find(user_id)
        rescue JWT::DecodeError, ActiveRecord::RecordNotFound
          render json: { error: 'Invalid or expired token' }, status: :unauthorized
        end
      end
      
      def current_user
        @current_user
      end
      
      def generate_backup_codes
        # Generate 10 backup codes (8 characters each)
        10.times.map { SecureRandom.alphanumeric(8).upcase }
      end
      
      def verify_mfa_code(code)
        # Try TOTP first
        totp = ROTP::TOTP.new(current_user.mfa_secret)
        return true if totp.verify(code, drift_behind: 30, drift_ahead: 30)
        
        # Try backup codes
        current_user.mfa_backup_codes&.each do |hashed_code|
          if BCrypt::Password.new(hashed_code) == code
            # Remove used backup code
            current_user.mfa_backup_codes.delete(hashed_code)
            current_user.save!
            return true
          end
        end
        
        false
      end
    end
  end
end
