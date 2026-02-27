# frozen_string_literal: true

# == Schema Information
#
# Table name: user_email_connections
#
#  id                        :bigint           not null, primary key
#  user_id                   :bigint           not null
#  company_id                :bigint           not null
#  provider                  :string           not null (smtp, oauth_gmail, oauth_outlook, company_domain)
#  email_address             :string           not null
#  display_name              :string
#  smtp_host                 :string
#  smtp_port                 :integer          default(587)
#  smtp_username             :string
#  smtp_password_encrypted   :text
#  smtp_authentication       :string           default("plain")
#  smtp_enable_tls           :boolean          default(true)
#  smtp_enable_starttls      :boolean          default(true)
#  oauth_token_encrypted     :text
#  oauth_refresh_token_encrypted :text
#  oauth_expires_at          :datetime
#  oauth_provider            :string
#  is_default                :boolean          default(false)
#  is_active                 :boolean          default(true)
#  verified_at               :datetime
#  verification_token        :string
#  verification_sent_at      :datetime
#  last_used_at              :datetime
#  last_error_at             :datetime
#  last_error_message        :text
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#

class UserEmailConnection < ApplicationRecord
  # Associations
  belongs_to :user
  belongs_to :company
  
  # Encryption for sensitive fields using Rails 7+ encryption
  # Requires config/credentials.yml.enc to have encryption keys
  encrypts :smtp_password_encrypted, deterministic: false
  encrypts :oauth_token_encrypted, deterministic: false
  encrypts :oauth_refresh_token_encrypted, deterministic: false
  
  # Provider types
  PROVIDERS = %w[smtp oauth_gmail oauth_outlook company_domain].freeze
  SMTP_AUTH_TYPES = %w[plain login cram_md5].freeze
  
  # Validations
  validates :email_address, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :smtp_authentication, inclusion: { in: SMTP_AUTH_TYPES }, allow_blank: true
  validates :smtp_port, numericality: { only_integer: true, greater_than: 0, less_than: 65536 }, allow_nil: true
  
  # SMTP validations when provider is smtp
  validates :smtp_host, presence: true, if: :smtp_provider?
  validates :smtp_username, presence: true, if: :smtp_provider?
  validates :smtp_password_encrypted, presence: true, if: -> { smtp_provider? && new_record? }
  
  # Scopes
  scope :active, -> { where(is_active: true) }
  scope :verified, -> { where.not(verified_at: nil) }
  scope :default_first, -> { order(is_default: :desc, created_at: :asc) }
  scope :for_user, ->(user) { where(user: user) }
  scope :smtp, -> { where(provider: 'smtp') }
  scope :oauth, -> { where(provider: %w[oauth_gmail oauth_outlook]) }
  
  # Callbacks
  before_validation :set_company_from_user
  before_save :ensure_single_default
  after_save :clear_user_email_cache
  
  # Check if verified
  def verified?
    verified_at.present?
  end
  
  # Check if this uses SMTP
  def smtp_provider?
    provider == 'smtp'
  end
  
  # Check if this is a company domain connection (no credentials needed)
  def company_domain_provider?
    provider == 'company_domain'
  end
  
  # Check if OAuth connection
  def oauth_provider?
    provider.start_with?('oauth_')
  end
  
  # Check if OAuth token needs refresh
  def oauth_token_expired?
    return false unless oauth_provider?
    return true if oauth_expires_at.nil?
    oauth_expires_at < Time.current
  end
  
  # Get the "from" address formatted for email
  def formatted_from_address
    if display_name.present?
      "#{display_name} <#{email_address}>"
    else
      email_address
    end
  end
  
  # Alias for convenience
  def smtp_password
    smtp_password_encrypted
  end
  
  def smtp_password=(value)
    self.smtp_password_encrypted = value
  end
  
  # Check if email matches a verified company domain
  def email_matches_verified_domain?
    return false unless company.present?
    
    domain = email_address.to_s.split('@').last&.downcase
    return false if domain.blank?
    
    verified_domains = company.verified_email_domains || []
    verified_domains.map(&:downcase).include?(domain)
  end
  
  # Determine if this connection requires verification
  def requires_verification?
    return false if verified?
    return false if email_matches_verified_domain?  # Auto-trust company domains
    return false if smtp_provider? && smtp_credentials_valid?  # SMTP creds = proof of access
    return false if oauth_provider? && oauth_token_encrypted.present?  # OAuth = proof of ownership
    true
  end
  
  # Check if SMTP credentials are configured
  def smtp_credentials_valid?
    smtp_host.present? && 
    smtp_username.present? && 
    smtp_password_encrypted.present?
  end
  
  # Generate verification token
  def generate_verification_token!
    self.verification_token = SecureRandom.urlsafe_base64(32)
    self.verification_sent_at = Time.current
    save!
    verification_token
  end
  
  # Verify with token
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
  
  # Mark as verified (for SMTP/OAuth that prove ownership)
  def mark_as_verified!
    update!(verified_at: Time.current) unless verified?
  end
  
  # Record successful use
  def record_usage!
    update_column(:last_used_at, Time.current)
  end
  
  # Record error
  def record_error!(message)
    update_columns(
      last_error_at: Time.current,
      last_error_message: message.to_s.truncate(500)
    )
  end
  
  # Clear error state
  def clear_error!
    update_columns(last_error_at: nil, last_error_message: nil)
  end
  
  # Test the SMTP connection
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
        # Connection successful
      end
      
      clear_error!
      mark_as_verified!
      
      { success: true, message: 'SMTP connection successful' }
    rescue Net::SMTPAuthenticationError => e
      record_error!("Authentication failed: #{e.message}")
      { success: false, error: "Authentication failed: #{e.message}" }
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      record_error!("Connection timeout: #{e.message}")
      { success: false, error: "Connection timeout - check host and port" }
    rescue SocketError => e
      record_error!("Connection failed: #{e.message}")
      { success: false, error: "Could not connect to #{smtp_host}:#{smtp_port}" }
    rescue => e
      record_error!(e.message)
      { success: false, error: e.message }
    end
  end
  
  # Build SMTP settings hash for ActionMailer
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
  # IMAP Methods for Sent Email Sync
  # ========================================
  
  # Derive IMAP server from SMTP server or OAuth provider
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

  # IMAP port (standard SSL port)
  def imap_port
    993
  end

  # Determine sent folder name based on provider
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

  # Check if IMAP is available for this connection
  def imap_available?
    if oauth_provider?
      email_address.present? && oauth_token_encrypted.present? && imap_server.present?
    else
      smtp_provider? && smtp_credentials_valid? && imap_server.present?
    end
  end
  
  # Test IMAP connection and return sent folder name
  def test_imap_connection!
    return { success: false, error: 'IMAP not available for this connection' } unless imap_available?

    begin
      imap = Net::IMAP.new(imap_server, imap_port, true)

      if oauth_provider?
        imap_authenticate_oauth!(imap)
      else
        imap.login(smtp_username, smtp_password_encrypted)
      end
      
      # Try to find sent folder
      sent_folder = nil
      sent_folder_names.each do |folder|
        begin
          imap.select(folder)
          sent_folder = folder
          break
        rescue Net::IMAP::NoResponseError
          # Folder doesn't exist, try next
        end
      end
      
      imap.logout
      imap.disconnect
      
      if sent_folder
        { success: true, message: "IMAP connection successful. Sent folder: #{sent_folder}" }
      else
        { success: false, error: "IMAP connected but couldn't find Sent folder. Tried: #{sent_folder_names.join(', ')}" }
      end
      
    rescue Net::IMAP::NoResponseError => e
      record_error!("IMAP Auth failed: #{e.message}")
      { success: false, error: "IMAP authentication failed: #{e.message}" }
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      record_error!("IMAP timeout: #{e.message}")
      { success: false, error: "IMAP connection timeout - check host and port" }
    rescue SocketError => e
      record_error!("IMAP connection failed: #{e.message}")
      { success: false, error: "Could not connect to #{imap_server}:#{imap_port}" }
    rescue => e
      record_error!(e.message)
      { success: false, error: e.message }
    end
  end
  
  # Authenticate to IMAP using XOAUTH2 for OAuth connections
  def imap_authenticate_oauth!(imap)
    token = oauth_token_encrypted
    email = email_address

    # Refresh token if expired
    if oauth_token_expired? && oauth_refresh_token_encrypted.present?
      refreshed = refresh_oauth_token!
      token = refreshed if refreshed
    end

    # Build XOAUTH2 string per RFC: "user={email}\x01auth=Bearer {token}\x01\x01"
    xoauth2_string = "user=#{email}\x01auth=Bearer #{token}\x01\x01"
    imap.authenticate('XOAUTH2', xoauth2_string)
  end

  # Refresh OAuth token and persist
  def refresh_oauth_token!
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

    uri = URI(token_url)
    req = Net::HTTP::Post.new(uri)
    req.set_form_data(
      client_id:     client_id,
      client_secret: client_secret,
      refresh_token: oauth_refresh_token_encrypted,
      grant_type:    'refresh_token'
    )
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    tokens = JSON.parse(res.body)

    return nil if tokens['error'].present?

    # Persist new tokens
    update!(
      oauth_token_encrypted: tokens['access_token'],
      oauth_expires_at: Time.current + tokens['expires_in'].to_i.seconds
    )

    tokens['access_token']
  rescue => e
    Rails.logger.error "[UserEmailConnection#refresh_oauth_token!] Failed: #{e.message}"
    nil
  end

  private

  def set_company_from_user
    self.company_id ||= user&.company_id
  end
  
  def ensure_single_default
    return unless is_default? && is_default_changed?
    
    # Unset default on other connections for this user
    UserEmailConnection
      .where(user_id: user_id, is_default: true)
      .where.not(id: id)
      .update_all(is_default: false)
  end
  
  def clear_user_email_cache
    # Clear any cached email settings for this user
    Rails.cache.delete("user_email_connection:#{user_id}")
  end
end
