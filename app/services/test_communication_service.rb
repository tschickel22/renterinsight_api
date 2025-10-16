# frozen_string_literal: true

class TestCommunicationService
  def initialize(settings, channel)
    @settings = settings.deep_symbolize_keys
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
  rescue => e
    Rails.logger.error "[TestCommunicationService] Error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: e.message, backtrace: e.backtrace.first(5) }
  end

  private

  def test_email
    provider = @settings[:provider] || 'smtp'

    # Decrypt sensitive fields
    decrypted_settings = decrypt_sensitive_fields(@settings, :email)

    case provider.to_sym
    when :smtp, :gmail
      test_smtp(decrypted_settings)
    when :sendgrid
      test_sendgrid(decrypted_settings)
    when :aws_ses
      test_aws_ses(decrypted_settings)
    else
      { success: false, error: "Unknown email provider: #{provider}" }
    end
  end

  def test_sms
    provider = @settings[:provider] || 'twilio'

    # Decrypt sensitive fields
    decrypted_settings = decrypt_sensitive_fields(@settings, :sms)

    case provider.to_sym
    when :twilio
      test_twilio(decrypted_settings)
    when :aws_sns
      test_aws_sns_sms(decrypted_settings)
    else
      { success: false, error: "Unknown SMS provider: #{provider}" }
    end
  end

  def test_smtp(settings)
    require 'net/smtp'

    host = settings[:smtpHost] || settings[:smtp_host]
    port = (settings[:smtpPort] || settings[:smtp_port] || 587).to_i
    username = settings[:smtpUsername] || settings[:smtp_username]
    password = settings[:smtpPassword] || settings[:smtp_password]

    Rails.logger.info "[TestCommunicationService] Testing SMTP: #{username}@#{host}:#{port}"

    # Try to establish connection
    smtp = Net::SMTP.new(host, port)
    smtp.enable_starttls_auto if port == 587

    smtp.start(host, username, password, :plain) do |connection|
      Rails.logger.info "[TestCommunicationService] SMTP connection successful"
    end

    {
      success: true,
      message: "Successfully connected to #{host}:#{port}",
      provider: 'smtp'
    }
  rescue => e
    Rails.logger.error "[TestCommunicationService] SMTP test failed: #{e.message}"
    { success: false, error: e.message, provider: 'smtp' }
  end

  def test_sendgrid(settings)
    require 'net/http'
    require 'uri'
    require 'json'

    api_key = settings[:sendgridApiKey] || settings[:sendgrid_api_key]

    unless api_key.present?
      return { success: false, error: 'SendGrid API key is missing' }
    end

    # Test by calling SendGrid's API key validation endpoint
    uri = URI.parse('https://api.sendgrid.com/v3/scopes')
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{api_key}"

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    if response.code.to_i == 200
      {
        success: true,
        message: 'SendGrid API key is valid',
        provider: 'sendgrid'
      }
    else
      {
        success: false,
        error: 'SendGrid API key is invalid or expired',
        provider: 'sendgrid'
      }
    end
  rescue => e
    Rails.logger.error "[TestCommunicationService] SendGrid test failed: #{e.message}"
    { success: false, error: e.message, provider: 'sendgrid' }
  end

  def test_aws_ses(settings)
    require 'aws-sdk-ses'

    access_key = settings[:awsAccessKeyId] || settings[:aws_access_key_id]
    secret_key = settings[:awsSecretAccessKey] || settings[:aws_secret_access_key]
    region = settings[:awsRegion] || settings[:aws_region] || 'us-east-1'

    unless access_key.present? && secret_key.present?
      return { success: false, error: 'AWS credentials are missing' }
    end

    # Create SES client
    ses = Aws::SES::Client.new(
      access_key_id: access_key,
      secret_access_key: secret_key,
      region: region
    )

    # Test by getting account send quota
    response = ses.get_send_quota

    {
      success: true,
      message: "Successfully connected to AWS SES in #{region}",
      provider: 'aws_ses',
      details: {
        max_24_hour_send: response.max_24_hour_send,
        sent_last_24_hours: response.sent_last_24_hours
      }
    }
  rescue Aws::SES::Errors::ServiceError => e
    Rails.logger.error "[TestCommunicationService] AWS SES test failed: #{e.message}"
    { success: false, error: e.message, provider: 'aws_ses' }
  rescue => e
    Rails.logger.error "[TestCommunicationService] AWS SES test failed: #{e.message}"
    { success: false, error: e.message, provider: 'aws_ses' }
  end

  def test_twilio(settings)
    require 'net/http'
    require 'uri'
    require 'json'

    account_sid = settings[:twilioAccountSid] || settings[:twilio_account_sid]
    auth_token = settings[:twilioAuthToken] || settings[:twilio_auth_token]

    unless account_sid.present? && auth_token.present?
      return { success: false, error: 'Twilio credentials are missing' }
    end

    Rails.logger.info "[TestCommunicationService] Testing Twilio: #{account_sid}"

    # Test by calling Twilio's account endpoint
    uri = URI.parse("https://api.twilio.com/2010-04-01/Accounts/#{account_sid}.json")
    request = Net::HTTP::Get.new(uri)
    request.basic_auth(account_sid, auth_token)

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    result = JSON.parse(response.body) rescue {}

    if response.code.to_i == 200
      {
        success: true,
        message: 'Twilio credentials are valid',
        provider: 'twilio',
        details: {
          account_sid: result['sid'],
          status: result['status']
        }
      }
    else
      {
        success: false,
        error: result['message'] || 'Twilio authentication failed',
        provider: 'twilio'
      }
    end
  rescue => e
    Rails.logger.error "[TestCommunicationService] Twilio test failed: #{e.message}"
    { success: false, error: e.message, provider: 'twilio' }
  end

  def test_aws_sns_sms(settings)
    require 'aws-sdk-sns'

    access_key = settings[:awsAccessKeyId] || settings[:aws_access_key_id]
    secret_key = settings[:awsSecretAccessKey] || settings[:aws_secret_access_key]
    region = settings[:awsRegion] || settings[:aws_region] || 'us-east-1'

    unless access_key.present? && secret_key.present?
      return { success: false, error: 'AWS credentials are missing' }
    end

    # Create SNS client
    sns = Aws::SNS::Client.new(
      access_key_id: access_key,
      secret_access_key: secret_key,
      region: region
    )

    # Test by getting SMS attributes
    response = sns.get_sms_attributes({
      attributes: ['MonthlySpendLimit', 'DeliveryStatusSuccessSamplingRate']
    })

    {
      success: true,
      message: "Successfully connected to AWS SNS in #{region}",
      provider: 'aws_sns',
      details: response.attributes
    }
  rescue Aws::SNS::Errors::ServiceError => e
    Rails.logger.error "[TestCommunicationService] AWS SNS test failed: #{e.message}"
    { success: false, error: e.message, provider: 'aws_sns' }
  rescue => e
    Rails.logger.error "[TestCommunicationService] AWS SNS test failed: #{e.message}"
    { success: false, error: e.message, provider: 'aws_sns' }
  end

  def decrypt_sensitive_fields(settings, channel)
    decrypted = settings.deep_dup

    case channel
    when :email
      decrypted[:smtpPassword] = decrypt_if_needed(decrypted[:smtpPassword] || decrypted[:smtp_password])
      decrypted[:gmailClientSecret] = decrypt_if_needed(decrypted[:gmailClientSecret] || decrypted[:gmail_client_secret])
      decrypted[:gmailRefreshToken] = decrypt_if_needed(decrypted[:gmailRefreshToken] || decrypted[:gmail_refresh_token])
      decrypted[:sendgridApiKey] = decrypt_if_needed(decrypted[:sendgridApiKey] || decrypted[:sendgrid_api_key])
      decrypted[:awsSecretAccessKey] = decrypt_if_needed(decrypted[:awsSecretAccessKey] || decrypted[:aws_secret_access_key])
    when :sms
      decrypted[:twilioAuthToken] = decrypt_if_needed(decrypted[:twilioAuthToken] || decrypted[:twilio_auth_token])
      decrypted[:awsSecretAccessKey] = decrypt_if_needed(decrypted[:awsSecretAccessKey] || decrypted[:aws_secret_access_key])
    end

    decrypted
  end

  def decrypt_if_needed(value)
    return value unless value.present?
    return value unless value.to_s.start_with?('encrypted:')

    encrypted_value = value.to_s.sub('encrypted:', '')
    decrypt(encrypted_value)
  rescue => e
    Rails.logger.error "[TestCommunicationService] Decryption error: #{e.message}"
    value
  end

  def decrypt(encrypted_value)
    secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
    key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
    crypt = ActiveSupport::MessageEncryptor.new(key)
    crypt.decrypt_and_verify(encrypted_value)
  rescue => e
    Rails.logger.error "[TestCommunicationService] Decrypt error: #{e.message}"
    nil
  end
end
