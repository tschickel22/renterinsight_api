# frozen_string_literal: true

class Company < ApplicationRecord
  has_many :accounts, dependent: :destroy
  has_many :contacts, dependent: :destroy
  has_many :deals, dependent: :destroy
  has_many :intake_forms, dependent: :destroy
  has_many :custom_fields, dependent: :destroy
  has_many :leads, dependent: :destroy
  has_many :vehicles, dependent: :destroy
  has_many :listings, dependent: :destroy
  has_many :syndication_partners, dependent: :destroy
  has_many :land_parcels, dependent: :destroy
  has_many :service_tickets, dependent: :destroy
  has_many :users, dependent: :destroy
  has_many :quotes, dependent: :destroy
  has_many :brochures, dependent: :destroy
  has_many :templates, dependent: :destroy
  has_many :locations, dependent: :destroy
  has_many :sources, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :territories, dependent: :destroy
  has_many :nurture_sequences, dependent: :destroy
  has_many :nurture_enrollments, dependent: :destroy
  
  # RBAC System Associations
  has_many :roles, dependent: :destroy
  has_many :company_hidden_roles, dependent: :destroy
  has_many :hidden_roles, through: :company_hidden_roles, source: :role
  
  # Validations for tenant fields
  validates :subdomain, 
            uniqueness: { case_sensitive: false, allow_nil: true },
            format: { with: /\A[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?\z/, allow_nil: true, 
                     message: "must be 1-63 characters, alphanumeric with dashes" },
            length: { minimum: 1, maximum: 63, allow_nil: true }
  
  validates :custom_domain,
            uniqueness: { case_sensitive: false, allow_nil: true },
            format: { with: /\A[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,}\z/i, allow_nil: true,
                     message: "must be a valid domain format" }
  
  validates :status, inclusion: { in: %w[active trial suspended cancelled], allow_nil: true }
  validates :subscription_tier, inclusion: { in: %w[free starter professional enterprise], allow_nil: true }
  
  # Scopes
  scope :active, -> { where(status: 'active') }
  scope :trial, -> { where(status: 'trial') }
  scope :trial_expiring_soon, -> { where(status: 'trial').where('trial_ends_at <= ?', 7.days.from_now) }
  
  # Domain verification methods
  def domain_verified?
    domain_verified_at.present?
  rescue
    false
  end
  
  def email_domain_verified?
    email_domain_verified_at.present?
  rescue
    false
  end
  
  def generate_domain_verification_token
    self.domain_verification_token = SecureRandom.hex(32)
    save
  rescue => e
    Rails.logger.error "Error generating domain token for Company #{id}: #{e.message}"
    false
  end
  
  # Check if domain verification TXT record exists
  def check_domain_verification
    return { success: false, error: 'No custom domain configured' } if custom_domain.blank?
    return { success: false, error: 'No verification token generated' } if domain_verification_token.blank?
    
    require 'resolv'
    
    begin
      resolver = Resolv::DNS.new
      txt_records = resolver.getresources(custom_domain, Resolv::DNS::Resource::IN::TXT)
      
      if txt_records.empty?
        return { 
          success: false, 
          error: 'No TXT records found for domain',
          details: 'Add TXT record to your DNS settings'
        }
      end
      
      # Look for our verification token in TXT records
      expected_value = "landlordinsight-verification=#{domain_verification_token}"
      found = txt_records.any? { |record| record.data == expected_value }
      
      if found
        { success: true, message: 'Domain verification record found' }
      else
        { 
          success: false, 
          error: 'Verification token not found in TXT records',
          expected: expected_value,
          found: txt_records.map(&:data)
        }
      end
    rescue Resolv::ResolvError => e
      { success: false, error: "DNS lookup failed: #{e.message}" }
    rescue => e
      Rails.logger.error "Domain verification check error for Company #{id}: #{e.message}"
      { success: false, error: "Verification failed: #{e.message}" }
    end
  end
  
  # Verify domain by checking DNS TXT record
  def verify_domain!
    verification_result = check_domain_verification
    
    if verification_result[:success]
      update!(domain_verified_at: Time.current)
      { success: true, message: 'Domain verified successfully' }
    else
      { success: false, error: verification_result[:error], details: verification_result }
    end
  rescue => e
    Rails.logger.error "Error verifying domain for Company #{id}: #{e.message}"
    { success: false, error: e.message }
  end
  
  # Check email domain DNS records (SPF, DKIM, DMARC)
  def check_email_dns_records
    return { success: false, error: 'No email domain configured' } if email_domain.blank?
    
    require 'resolv'
    
    begin
      resolver = Resolv::DNS.new
      results = {
        spf: { status: 'not_found', record: nil },
        dkim: { status: 'not_found', record: nil },
        dmarc: { status: 'not_found', record: nil }
      }
      
      # Check SPF record (TXT at root domain)
      begin
        txt_records = resolver.getresources(email_domain, Resolv::DNS::Resource::IN::TXT)
        spf_record = txt_records.find { |r| r.data.start_with?('v=spf1') }
        
        if spf_record
          if spf_record.data.include?('landlordinsight.com')
            results[:spf] = { status: 'valid', record: spf_record.data }
          else
            results[:spf] = { status: 'invalid', record: spf_record.data, error: 'Does not include landlordinsight.com' }
          end
        end
      rescue Resolv::ResolvError
        results[:spf][:error] = 'DNS lookup failed'
      end
      
      # Check DKIM record (TXT at mail._domainkey.domain)
      begin
        dkim_domain = "mail._domainkey.#{email_domain}"
        dkim_records = resolver.getresources(dkim_domain, Resolv::DNS::Resource::IN::TXT)
        dkim_record = dkim_records.find { |r| r.data.start_with?('v=DKIM1') }
        
        if dkim_record
          results[:dkim] = { status: 'valid', record: dkim_record.data }
        end
      rescue Resolv::ResolvError
        results[:dkim][:error] = 'DNS lookup failed'
      end
      
      # Check DMARC record (TXT at _dmarc.domain)
      begin
        dmarc_domain = "_dmarc.#{email_domain}"
        dmarc_records = resolver.getresources(dmarc_domain, Resolv::DNS::Resource::IN::TXT)
        dmarc_record = dmarc_records.find { |r| r.data.start_with?('v=DMARC1') }
        
        if dmarc_record
          results[:dmarc] = { status: 'valid', record: dmarc_record.data }
        end
      rescue Resolv::ResolvError
        results[:dmarc][:error] = 'DNS lookup failed'
      end
      
      # Determine overall success (at least SPF must be valid)
      if results[:spf][:status] == 'valid'
        { success: true, message: 'Email DNS records found', records: results }
      else
        { 
          success: false, 
          error: 'SPF record is required and must include landlordinsight.com',
          records: results 
        }
      end
    rescue => e
      Rails.logger.error "Email DNS check error for Company #{id}: #{e.message}"
      { success: false, error: "DNS check failed: #{e.message}" }
    end
  end
  
  # Verify email domain by checking DNS records
  def verify_email_domain!
    verification_result = check_email_dns_records
    
    if verification_result[:success]
      update!(email_domain_verified_at: Time.current)
      { success: true, message: 'Email domain verified successfully', records: verification_result[:records] }
    else
      { success: false, error: verification_result[:error], records: verification_result[:records] }
    end
  rescue => e
    Rails.logger.error "Error verifying email domain for Company #{id}: #{e.message}"
    { success: false, error: e.message }
  end
  
  # Tenant status methods
  def active?
    status == 'active'
  end
  
  def trial?
    status == 'trial'
  end
  
  def trial_expired?
    trial? && trial_ends_at.present? && trial_ends_at < Time.current
  end
  
  def suspended?
    status == 'suspended'
  end
  
  def cancelled?
    status == 'cancelled'
  end
  
  # Usage limits
  def can_add_user?
    return true if max_users.nil?
    users.where(deleted_at: nil).count < max_users
  end
  
  def users_remaining
    return nil if max_users.nil?
    remaining = max_users - users.where(deleted_at: nil).count
    [remaining, 0].max
  end
  
  def users_count
    users.where(deleted_at: nil).count
  end
  
  # Primary domain resolution (custom domain takes precedence over subdomain)
  def primary_domain
    custom_domain.presence || subdomain_url
  rescue
    subdomain
  end
  
  def subdomain_url
    return nil if subdomain.blank?
    # This will be configured based on environment
    base_domain = ENV.fetch('TENANT_BASE_DOMAIN', 'crm.landlordinsight.com')
    "#{subdomain}.#{base_domain}"
  rescue
    nil
  end
  
  # Settings management
  def communications_settings
    setting = Setting.find_by(scope_type: 'Company', scope_id: id, key: 'communications')
    setting ? JSON.parse(setting.value) : nil
  rescue => e
    Rails.logger.error "Error loading communications_settings for Company #{id}: #{e.message}"
    nil
  end
  
  def communications_settings=(value)
    Rails.logger.info "📝 [Company#communications_settings=] Setting for Company #{id}"
    
    setting = Setting.find_or_initialize_by(
      scope_type: 'Company',
      scope_id: id,
      key: 'communications'
    )
    setting.value = value.to_json
    
    if setting.save!
      Rails.logger.info "✅ [Company#communications_settings=] Saved successfully"
      true
    end
  rescue => e
    Rails.logger.error "❌ [Company#communications_settings=] Error: #{e.class} - #{e.message}"
    raise e
  end
  
  def notifications_settings
    setting = Setting.find_by(scope_type: 'Company', scope_id: id, key: 'notifications')
    setting ? JSON.parse(setting.value) : nil
  rescue => e
    Rails.logger.error "Error loading notifications_settings for Company #{id}: #{e.message}"
    nil
  end
  
  def notifications_settings=(value)
    Rails.logger.info "📝 [Company#notifications_settings=] Setting for Company #{id}"
    
    setting = Setting.find_or_initialize_by(
      scope_type: 'Company',
      scope_id: id,
      key: 'notifications'
    )
    setting.value = value.to_json
    
    if setting.save!
      Rails.logger.info "✅ [Company#notifications_settings=] Saved successfully"
      true
    end
  rescue => e
    Rails.logger.error "❌ [Company#notifications_settings=] Error: #{e.class} - #{e.message}"
    raise e
  end

  def branding_settings
    setting = Setting.find_by(scope_type: 'Company', scope_id: id, key: 'branding')
    setting ? JSON.parse(setting.value) : nil
  rescue => e
    Rails.logger.error "Error loading branding_settings for Company #{id}: #{e.message}"
    nil
  end
  
  def branding_settings=(value)
    Rails.logger.info "📝 [Company#branding_settings=] Setting for Company #{id}"
    
    setting = Setting.find_or_initialize_by(
      scope_type: 'Company',
      scope_id: id,
      key: 'branding'
    )
    setting.value = value.to_json
    
    if setting.save!
      Rails.logger.info "✅ [Company#branding_settings=] Saved successfully"
      true
    end
  rescue => e
    Rails.logger.error "❌ [Company#branding_settings=] Error: #{e.class} - #{e.message}"
    raise e
  end

  def integration_settings
    setting = Setting.find_by(scope_type: 'Company', scope_id: id, key: 'integrations')
    setting ? JSON.parse(setting.value) : nil
  rescue => e
    Rails.logger.error "Error loading integration_settings for Company #{id}: #{e.message}"
    nil
  end
  
  def integration_settings=(value)
    Rails.logger.info "📝 [Company#integration_settings=] Setting for Company #{id}"
    
    setting = Setting.find_or_initialize_by(
      scope_type: 'Company',
      scope_id: id,
      key: 'integrations'
    )
    setting.value = value.to_json
    
    if setting.save!
      Rails.logger.info "✅ [Company#integration_settings=] Saved successfully"
      true
    end
  rescue => e
    Rails.logger.error "❌ [Company#integration_settings=] Error: #{e.class} - #{e.message}"
    raise e
  end

  def operational_settings
    setting = Setting.find_by(scope_type: 'Company', scope_id: id, key: 'operational')
    setting ? JSON.parse(setting.value) : nil
  rescue => e
    Rails.logger.error "Error loading operational_settings for Company #{id}: #{e.message}"
    nil
  end
  
  def operational_settings=(value)
    Rails.logger.info "📝 [Company#operational_settings=] Setting operational settings for Company #{id}"
    Rails.logger.info "📝 [Company#operational_settings=] Value: #{value.inspect}"
    
    setting = Setting.find_or_initialize_by(
      scope_type: 'Company',
      scope_id: id,
      key: 'operational'
    )
    
    Rails.logger.info "📝 [Company#operational_settings=] Setting record: #{setting.inspect}"
    
    setting.value = value.to_json
    Rails.logger.info "📝 [Company#operational_settings=] JSON value: #{setting.value}"
    
    if setting.save!
      Rails.logger.info "✅ [Company#operational_settings=] Setting saved successfully"
      true
    end
  rescue => e
    Rails.logger.error "❌ [Company#operational_settings=] Error: #{e.class} - #{e.message}"
    Rails.logger.error "❌ [Company#operational_settings=] Backtrace: #{e.backtrace.first(5).join("\n")}"
    raise e
  end

  # Check if company has meaningful communication settings configured
  def has_communication_settings?
    comm_settings = communications_settings
    return false if comm_settings.nil? || comm_settings.empty?
    
    # Check if email settings have required fields
    email_settings = comm_settings['email'] || comm_settings[:email]
    if email_settings.present?
      # Has email if there's a provider and from email configured
      has_email = email_settings['fromEmail'].present? || email_settings[:fromEmail].present?
      return true if has_email
    end
    
    # Check if SMS settings have required fields
    sms_settings = comm_settings['sms'] || comm_settings[:sms]
    if sms_settings.present?
      # Has SMS if there's a provider and from number configured
      has_sms = sms_settings['fromNumber'].present? || sms_settings[:fromNumber].present?
      return true if has_sms
    end
    
    false
  rescue => e
    Rails.logger.error "Error checking communication settings for Company #{id}: #{e.message}"
    false
  end
end
