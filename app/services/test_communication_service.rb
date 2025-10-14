# frozen_string_literal: true

# Service to test email and SMS configurations before saving
class TestCommunicationService
  class TestError < StandardError; end

  def initialize(settings, channel)
    @settings = settings
    @channel = channel.to_sym
  end

  def test
    case @channel
    when :email
      test_email
    when :sms
      test_sms
    else
      { success: false, error: "Unknown channel: #{@channel}" }
    end
  rescue StandardError => e
    Rails.logger.error("[TestCommunicationService] Error: #{e.message}")
    { success: false, error: e.message, backtrace: e.backtrace.first(3) }
  end

  private

  def test_email
    provider = @settings[:provider]&.to_sym || :smtp
    
    case provider
    when :smtp
      test_smtp
    when :gmail
      test_gmail
    when :sendgrid
      test_sendgrid
    when :aws_ses
      test_aws_ses
    else
      { success: false, error: "Unknown email provider: #{provider}" }
    end
  end

  def test_sms
    provider = @settings[:provider]&.to_sym || :twilio
    
    case provider
    when :twilio
      test_twilio
    when :aws_sns
      test_aws_sns
    else
      { success: false, error: "Unknown SMS provider: #{provider}" }
    end
  end

  def test_smtp
    require 'net/smtp'
    
    host = @settings[:smtpHost] || @settings[:smtp_host]
    port = (@settings[:smtpPort] || @settings[:smtp_port] || 587).to_i
    username = @settings[:smtpUsername] || @settings[:smtp_username]
    password = decrypt_if_needed(@settings[:smtpPassword] || @settings[:smtp_password])
    from_email = @settings[:fromEmail] || @settings[:from_email]
    
    return { success: false, error: 'SMTP host is required' } if host.blank?
    return { success: false, error: 'From email is required' } if from_email.blank?
    
    smtp = Net::SMTP.new(host, port)
    smtp.enable_starttls_auto if port == 587
    
    if username.present? && password.present?
      smtp.start(host, username, password, :plain) do |smtp_conn|
        # Connection successful
      end
    else
      smtp.start(host) do |smtp_conn|
        # Connection successful
      end
    end
    
    { 
      success: true, 
      message: "Successfully connected to SMTP server at #{host}:#{port}",
      provider: 'smtp'
    }
  rescue Net::SMTPAuthenticationError => e
    { success: false, error: "SMTP authentication failed: #{e.message}" }
  rescue SocketError => e
    { success: false, error: "Could not connect to SMTP server: #{e.message}" }
  rescue StandardError => e
    { success: false, error: "SMTP test failed: #{e.message}" }
  end

  def test_gmail
    client_id = @settings[:gmailClientId] || @settings[:gmail_client_id]
    from_email = @settings[:fromEmail] || @settings[:from_email]
    
    return { success: false, error: 'Gmail OAuth client ID is required' } if client_id.blank?
    return { success: false, error: 'From email is required' } if from_email.blank?
    
    { 
      success: true, 
      message: 'Gmail OAuth configuration looks valid',
      provider: 'gmail'
    }
  end

  def test_sendgrid
    api_key = decrypt_if_needed(@settings[:sendgridApiKey] || @settings[:sendgrid_api_key])
    from_email = @settings[:fromEmail] || @settings[:from_email]
    
    return { success: false, error: 'SendGrid API key is required' } if api_key.blank?
    return { success: false, error: 'From email is required' } if from_email.blank?
    
    { 
      success: true, 
      message: 'SendGrid configuration looks valid',
      provider: 'sendgrid'
    }
  end

  def test_aws_ses
    access_key = decrypt_if_needed(@settings[:awsAccessKeyId] || @settings[:aws_access_key_id])
    from_email = @settings[:fromEmail] || @settings[:from_email]
    
    return { success: false, error: 'AWS access key is required' } if access_key.blank?
    return { success: false, error: 'From email is required' } if from_email.blank?
    
    { 
      success: true, 
      message: 'AWS SES configuration looks valid',
      provider: 'aws_ses'
    }
  end

  def test_twilio
    account_sid = @settings[:twilioAccountSid] || @settings[:twilio_account_sid]
    from_number = @settings[:fromNumber] || @settings[:from_number]
    
    return { success: false, error: 'Twilio Account SID is required' } if account_sid.blank?
    return { success: false, error: 'From phone number is required' } if from_number.blank?
    
    { 
      success: true, 
      message: 'Twilio configuration looks valid',
      provider: 'twilio'
    }
  end

  def test_aws_sns
    access_key = decrypt_if_needed(@settings[:awsAccessKeyId] || @settings[:aws_access_key_id])
    
    return { success: false, error: 'AWS access key is required' } if access_key.blank?
    
    { 
      success: true, 
      message: 'AWS SNS configuration looks valid',
      provider: 'aws_sns'
    }
  end

  def decrypt_if_needed(value)
    return value unless value.present?
    return value unless value.start_with?('encrypted:')
    
    encrypted_value = value.sub('encrypted:', '')
    decrypt(encrypted_value)
  rescue StandardError => e
    Rails.logger.error("[TestCommunicationService] Decryption failed: #{e.message}")
    nil
  end

  def decrypt(encrypted_value)
    secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
    # Ensure key is exactly 32 bytes for AES-256
    key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
    crypt = ActiveSupport::MessageEncryptor.new(key)
    crypt.decrypt_and_verify(encrypted_value)
  rescue StandardError => e
    Rails.logger.error("[TestCommunicationService] Failed to decrypt: #{e.message}")
    nil
  end
end
