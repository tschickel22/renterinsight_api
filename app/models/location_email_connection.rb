# frozen_string_literal: true

# == Schema Information
#
# Table name: location_email_connections
#
# Same shape as user_email_connections, scoped per location instead of per user.
# One connection per location (enforced by unique index on location_id).

class LocationEmailConnection < ApplicationRecord
  # Associations
  belongs_to :location
  belongs_to :company

  # Encryption for sensitive fields using Rails 7+ encryption
  encrypts :smtp_password_encrypted, deterministic: false
  encrypts :oauth_token_encrypted, deterministic: false
  encrypts :oauth_refresh_token_encrypted, deterministic: false

  PROVIDERS = %w[smtp oauth_gmail oauth_outlook company_domain].freeze
  SMTP_AUTH_TYPES = %w[plain login cram_md5].freeze

  validates :email_address, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :smtp_authentication, inclusion: { in: SMTP_AUTH_TYPES }, allow_blank: true
  validates :smtp_port, numericality: { only_integer: true, greater_than: 0, less_than: 65536 }, allow_nil: true

  validates :smtp_host, presence: true, if: :smtp_provider?
  validates :smtp_username, presence: true, if: :smtp_provider?
  validates :smtp_password_encrypted, presence: true, if: -> { smtp_provider? && new_record? }

  scope :active, -> { where(is_active: true) }
  scope :verified, -> { where.not(verified_at: nil) }
  scope :for_location, ->(location) { where(location: location) }
  scope :smtp, -> { where(provider: 'smtp') }
  scope :oauth, -> { where(provider: %w[oauth_gmail oauth_outlook]) }

  before_validation :set_company_from_location

  def verified?
    verified_at.present?
  end

  def smtp_provider?
    provider == 'smtp'
  end

  def company_domain_provider?
    provider == 'company_domain'
  end

  def oauth_provider?
    provider.start_with?('oauth_')
  end

  def oauth_token_expired?
    return false unless oauth_provider?
    return true if oauth_expires_at.nil?
    oauth_expires_at < Time.current
  end

  def formatted_from_address
    if display_name.present?
      "#{display_name} <#{email_address}>"
    else
      email_address
    end
  end

  def smtp_password
    smtp_password_encrypted
  end

  def smtp_password=(value)
    self.smtp_password_encrypted = value
  end

  def email_matches_verified_domain?
    return false unless company.present?
    domain = email_address.to_s.split('@').last&.downcase
    return false if domain.blank?
    verified_domains = company.verified_email_domains || []
    verified_domains.map(&:downcase).include?(domain)
  end

  def requires_verification?
    return false if verified?
    return false if email_matches_verified_domain?
    return false if smtp_provider? && smtp_credentials_valid?
    return false if oauth_provider? && oauth_token_encrypted.present?
    true
  end

  def smtp_credentials_valid?
    smtp_host.present? &&
    smtp_username.present? &&
    smtp_password_encrypted.present?
  end

  def generate_verification_token!
    self.verification_token = SecureRandom.urlsafe_base64(32)
    self.verification_sent_at = Time.current
    save!
    verification_token
  end

  def verify_with_token!(token)
    return false unless verification_token == token
    return false if verification_sent_at.present? && verification_sent_at < 24.hours.ago

    update!(
      verified_at: Time.current,
      verification_token: nil,
      verification_sent_at: nil
    )
    true
  end

  def mark_as_verified!
    update!(verified_at: Time.current) unless verified?
  end

  def record_usage!
    update_column(:last_used_at, Time.current)
  end

  def record_error!(message)
    update_columns(
      last_error_at: Time.current,
      last_error_message: message.to_s.truncate(500)
    )
  end

  def clear_error!
    update_columns(last_error_at: nil, last_error_message: nil)
  end

  def test_smtp_connection!
    return { success: false, error: 'Not an SMTP connection' } unless smtp_provider?
    return { success: false, error: 'Missing SMTP credentials' } unless smtp_credentials_valid?

    begin
      smtp = Net::SMTP.new(smtp_host, smtp_port || 587)
      smtp.enable_starttls_auto if smtp_enable_starttls
      smtp.enable_tls if smtp_enable_tls && !smtp_enable_starttls
      smtp.open_timeout = 10
      smtp.read_timeout = 10
      smtp.start('localhost', smtp_username, smtp_password_encrypted, smtp_authentication&.to_sym || :plain) do |s|
      end
      clear_error!
      mark_as_verified!
      { success: true, message: 'SMTP connection successful' }
    rescue Net::SMTPAuthenticationError => e
      record_error!("Authentication failed: #{e.message}")
      { success: false, error: "Authentication failed: #{e.message}" }
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      record_error!("Connection timeout: #{e.message}")
      { success: false, error: 'Connection timeout - check host and port' }
    rescue SocketError => e
      record_error!("Connection failed: #{e.message}")
      { success: false, error: "Could not connect to #{smtp_host}:#{smtp_port}" }
    rescue => e
      record_error!(e.message)
      { success: false, error: e.message }
    end
  end

  def to_smtp_settings
    return nil unless smtp_provider? && smtp_credentials_valid?
    {
      address: smtp_host,
      port: smtp_port || 587,
      user_name: smtp_username,
      password: smtp_password_encrypted,
      authentication: (smtp_authentication || 'plain').to_sym,
      enable_starttls_auto: smtp_enable_starttls,
      openssl_verify_mode: smtp_enable_tls ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
    }.compact
  end

  # ========================================
  # IMAP Methods
  # ========================================

  def imap_server
    if oauth_provider?
      case provider
      when 'oauth_gmail'  then 'imap.gmail.com'
      when 'oauth_outlook' then 'outlook.office365.com'
      end
    elsif smtp_provider? && smtp_host.present?
      case smtp_host.downcase
      when 'smtp.gmail.com'
        'imap.gmail.com'
      when 'smtp.office365.com', 'smtp-mail.outlook.com', 'outlook.office365.com'
        'outlook.office365.com'
      when /^smtp\./
        smtp_host.gsub(/^smtp\./, 'imap.')
      end
    end
  end

  def imap_port
    993
  end

  def sent_folder_names
    if oauth_provider?
      case provider
      when 'oauth_gmail'   then ['[Gmail]/Sent Mail', 'Sent', '[Gmail]/Sent']
      when 'oauth_outlook' then ['Sent Items', 'Sent']
      else ['Sent', 'Sent Items', 'Sent Messages']
      end
    elsif smtp_host.present?
      case smtp_host.downcase
      when 'smtp.gmail.com'
        ['[Gmail]/Sent Mail', 'Sent', '[Gmail]/Sent']
      when 'smtp.office365.com', 'smtp-mail.outlook.com', 'outlook.office365.com'
        ['Sent Items', 'Sent']
      else
        ['Sent', 'Sent Items', 'Sent Messages']
      end
    else
      []
    end
  end

  def imap_available?
    if oauth_provider?
      email_address.present? && oauth_token_encrypted.present? && imap_server.present?
    else
      smtp_provider? && smtp_credentials_valid? && imap_server.present?
    end
  end

  def imap_authenticate_oauth!(imap)
    token = oauth_token_encrypted
    email = email_address
    if oauth_token_expired? && oauth_refresh_token_encrypted.present?
      refreshed = refresh_oauth_token!
      token = refreshed if refreshed
    end
    imap.authenticate('XOAUTH2', email, token)
  end

  def refresh_oauth_token!(scope: nil)
    oauth_type = provider == 'oauth_gmail' ? :google : :microsoft
    token_url = case oauth_type
                when :microsoft then 'https://login.microsoftonline.com/common/oauth2/v2.0/token'
                when :google    then 'https://oauth2.googleapis.com/token'
                end

    provider_name = oauth_type == :microsoft ? 'MICROSOFT' : 'GOOGLE'
    client_id     = ENV["#{provider_name}_OAUTH_CLIENT_ID"] ||
                    Rails.application.credentials.dig(:oauth, oauth_type, :client_id)
    client_secret = ENV["#{provider_name}_OAUTH_CLIENT_SECRET"] ||
                    Rails.application.credentials.dig(:oauth, oauth_type, :client_secret)

    form_data = {
      client_id:     client_id,
      client_secret: client_secret,
      refresh_token: oauth_refresh_token_encrypted,
      grant_type:    'refresh_token'
    }
    form_data[:scope] = scope if scope.present?

    uri = URI(token_url)
    req = Net::HTTP::Post.new(uri)
    req.set_form_data(form_data)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    tokens = JSON.parse(res.body)

    return nil if tokens['error'].present?

    attrs = {
      oauth_token_encrypted: tokens['access_token'],
      oauth_expires_at: Time.current + tokens['expires_in'].to_i.seconds
    }
    attrs[:oauth_refresh_token_encrypted] = tokens['refresh_token'] if tokens['refresh_token'].present?
    update!(attrs)

    tokens['access_token']
  rescue => e
    Rails.logger.error "[LocationEmailConnection#refresh_oauth_token!] Failed: #{e.message}"
    nil
  end

  GRAPH_SEND_SCOPE = 'https://graph.microsoft.com/Mail.Send offline_access'.freeze
  GRAPH_FULL_SCOPE = 'https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/Mail.Read offline_access'.freeze

  def refresh_oauth_token_for_graph!
    refresh_oauth_token!(scope: GRAPH_SEND_SCOPE)
  end

  def refresh_oauth_token_for_graph_read!
    refresh_oauth_token!(scope: GRAPH_FULL_SCOPE)
  end

  def ensure_graph_token!
    token = oauth_token_encrypted
    if oauth_token_expired? && oauth_refresh_token_encrypted.present?
      refreshed = refresh_oauth_token_for_graph_read! || refresh_oauth_token_for_graph!
      token = refreshed if refreshed
    end
    token
  end

  private

  def set_company_from_location
    self.company_id ||= location&.company_id
  end
end
