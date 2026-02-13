# frozen_string_literal: true

class Company < ApplicationRecord
  include QuickbooksIntegration
  
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
  has_many :bank_accounts, dependent: :destroy
  has_many :invitations, dependent: :destroy  # Tenant owner invitations
  
  # Commission Engine Associations
  has_many :commission_rules, dependent: :destroy
  has_many :commissions, dependent: :destroy
  has_many :commission_components, dependent: :destroy
  has_many :commission_plans, dependent: :destroy
  has_many :commission_payments, dependent: :destroy
  has_many :sources, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :territories, dependent: :destroy
  has_many :nurture_sequences, dependent: :destroy
  has_many :nurture_enrollments, dependent: :destroy
  
  # Finance Module Associations
  has_many :payment_methods, dependent: :destroy
  has_many :payments, dependent: :destroy
  has_many :loans, dependent: :destroy
  has_many :invoices, dependent: :destroy
  
  # Tasks Module
  has_many :tasks, dependent: :destroy
  
  # Warranty & Service Module Associations
  has_many :company_manufacturers, dependent: :destroy
  has_many :manufacturers, through: :company_manufacturers
  has_many :warranty_claims, dependent: :destroy
  has_many :manufacturer_ar_transactions, dependent: :destroy
  has_many :manufacturer_ar_payments, dependent: :destroy
  
  # Parts & Inventory Module Associations
  has_many :part_categories, dependent: :destroy
  has_many :parts, dependent: :destroy
  has_many :suppliers, dependent: :destroy
  has_many :purchase_orders, dependent: :destroy
  has_many :inventory_transactions, dependent: :destroy
  has_many :stock_balances, dependent: :destroy
  has_many :reorder_rules, dependent: :destroy
  
  # Website Builder Associations
  has_many :websites, dependent: :destroy
  has_many :sites, dependent: :destroy
  has_many :site_media, dependent: :destroy
  has_many :website_media, class_name: 'WebsiteMedia', dependent: :destroy  # Media for websites
  has_many :company_domains, dependent: :destroy
  
  # RBAC System Associations
  has_many :roles, dependent: :destroy
  has_many :company_hidden_roles, dependent: :destroy
  has_many :hidden_roles, through: :company_hidden_roles, source: :role
  
  # Subscription System Associations
  has_one :tenant_subscription, dependent: :destroy
  has_many :tenant_module_overrides, dependent: :destroy
  
  # QuickBooks Integration Associations
  has_many :quickbooks_field_mappings, dependent: :destroy
  has_many :quickbooks_sync_logs, dependent: :destroy
  
  # Enums
  enum :quickbooks_scope, { company: 'company', location: 'location' }, prefix: true, default: :company
  
  # Public Inventory Settings (JSONB store)
  store_accessor :public_inventory_settings,
    :public_inventory_enabled,        # boolean - enable/disable public inventory
    :public_statuses,                 # array - which statuses to show publicly (e.g., ['available', 'on_order'])
    :show_pricing,                    # boolean - show prices on public listings
    :show_contact_button,             # boolean - show "Request Info" button
    :contact_button_text,             # string - custom button text
    :require_approval,                # boolean - admin must approve each public listing
    :items_per_page,                  # integer - pagination (default 12)
    :default_layout,                  # string - 'grid' or 'list'
    :show_filters                     # boolean - show filter sidebar
  
  # Callbacks
  after_create :create_default_location
  before_create :generate_public_inventory_token
  before_create :set_default_public_inventory_settings
  
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
  
  # Fiscal year validation (1-12 for January-December)
  validates :fiscal_year_start_month, 
            inclusion: { in: 1..12 }, 
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 12 },
            allow_nil: false
  
  # Scopes
  scope :active, -> { where(status: 'active') }
  scope :trial, -> { where(status: 'trial') }
  scope :trial_expiring_soon, -> { where(status: 'trial').where('trial_ends_at <= ?', 7.days.from_now) }
  
  # QuickBooks scopes
  scope :with_quickbooks_enabled, -> { where("quickbooks_realm_id IS NOT NULL AND (quickbooks_settings->>'enabled')::boolean = true") }
  scope :with_expired_quickbooks_tokens, -> { where('quickbooks_token_expires_at < ?', Time.current) }
  
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
      
      # Check SPF record
      begin
        spf_records = resolver.getresources(email_domain, Resolv::DNS::Resource::IN::TXT)
        spf_record = spf_records.find { |r| r.data.start_with?('v=spf1') }
        if spf_record
          results[:spf] = { status: 'found', record: spf_record.data }
        end
      rescue => e
        results[:spf] = { status: 'error', error: e.message }
      end
      
      # Check DKIM record (using default selector)
      begin
        dkim_domain = "default._domainkey.#{email_domain}"
        dkim_records = resolver.getresources(dkim_domain, Resolv::DNS::Resource::IN::TXT)
        dkim_record = dkim_records.find { |r| r.data.include?('k=rsa') }
        if dkim_record
          results[:dkim] = { status: 'found', record: dkim_record.data }
        end
      rescue => e
        results[:dkim] = { status: 'error', error: e.message }
      end
      
      # Check DMARC record
      begin
        dmarc_domain = "_dmarc.#{email_domain}"
        dmarc_records = resolver.getresources(dmarc_domain, Resolv::DNS::Resource::IN::TXT)
        dmarc_record = dmarc_records.find { |r| r.data.start_with?('v=DMARC1') }
        if dmarc_record
          results[:dmarc] = { status: 'found', record: dmarc_record.data }
        end
      rescue => e
        results[:dmarc] = { status: 'error', error: e.message }
      end
      
      { success: true, results: results }
    rescue => e
      Rails.logger.error "Email DNS check error for Company #{id}: #{e.message}"
      { success: false, error: e.message }
    end
  end
  
  # Verify email domain by checking DNS records
  def verify_email_domain!
    dns_results = check_email_dns_records
    
    if dns_results[:success]
      results = dns_results[:results]
      # Require at least SPF and DMARC to be configured
      if results[:spf][:status] == 'found' && results[:dmarc][:status] == 'found'
        update!(email_domain_verified_at: Time.current)
        { success: true, message: 'Email domain verified successfully', details: results }
      else
        { 
          success: false, 
          error: 'Required DNS records not found. Please configure SPF and DMARC records.',
          details: results 
        }
      end
    else
      { success: false, error: dns_results[:error] }
    end
  rescue => e
    Rails.logger.error "Error verifying email domain for Company #{id}: #{e.message}"
    { success: false, error: e.message }
  end
  
  # Get domain for routing (prefer custom domain over subdomain)
  def primary_domain
    custom_domain.presence || subdomain_with_base_domain
  end
  
  def subdomain_with_base_domain
    return nil unless subdomain.present?
    base_domain = Rails.application.credentials.dig(:domain, :base) || 'renterinsight.com'
    "#{subdomain}.#{base_domain}"
  end
  
  # Full URL for subdomain access
  def subdomain_url
    domain = subdomain_with_base_domain
    return nil unless domain.present?
    
    protocol = Rails.env.production? ? 'https' : 'https'
    "#{protocol}://#{domain}"
  end
  
  # Check if this company should receive traffic for the given host
  def matches_host?(host)
    return false if host.blank?
    
    # Normalize host (remove port if present)
    normalized_host = host.split(':').first.downcase
    
    # Check custom domain
    return true if custom_domain.present? && custom_domain.downcase == normalized_host
    
    # Check subdomain
    return true if subdomain.present? && subdomain_with_base_domain&.downcase == normalized_host
    
    false
  end
  
  # Tenant status checks
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
  
  # Settings helpers
  def operational_settings
    @operational_settings ||= Setting.get('Company', id, 'operational') || {}
  end
  
  def branding_settings
    @branding_settings ||= Setting.get('Company', id, 'branding') || {}
  end
  
  def communication_settings
    @communication_settings ||= Setting.get('Company', id, 'communication') || {}
  end
  
  def integration_settings
    @integration_settings ||= Setting.get('Company', id, 'integration') || {}
  end
  
  # Branding helpers - extract logo from settings
  def logo
    branding_settings&.dig('logo')
  end
  
  # Use the same bank account for deposits and rent collections
  # If true, all payments go to operating account
  # If false, deposits go to deposit account, rent goes to operating account
  def use_same_bank_account_for_deposits
    operational_settings['use_same_bank_account_for_deposits'] || false
  end
  
  # Company counts (for platform admin dashboard)
  def users_count
    users.where(deleted_at: nil).count
  end
  
  def active_users_count
    users.where(deleted_at: nil, status: 'active').count
  end
  
  def leads_count
    leads.where(is_deleted: false).count
  end
  
  def contacts_count
    contacts.where(is_deleted: false).count
  end
  
  def deals_count
    deals.where(is_deleted: false).count
  end
  
  def service_tickets_count
    service_tickets.where(is_deleted: false).count
  end
  
  def vehicles_count
    vehicles.where(is_deleted: false).count
  end
  
  def listings_count
    listings.where(is_deleted: false).count
  end
  
  def quotes_count
    quotes.where(is_deleted: false).count
  end
  
  def invoices_count
    invoices.where(is_deleted: false).count
  end
  
  def locations_count
    locations.count
  end
  
  # RBAC System Methods
  def uses_rbac_system?
    use_rbac_system == true
  end
  
  def rbac_enabled?
    uses_rbac_system?
  end
  
  # Get all available roles for this company (system roles + custom roles)
  def available_roles
    system_roles = Role.system_roles
    custom_company_roles = roles.where(is_system_role: false, is_deleted: false)
    
    # Filter out hidden roles
    hidden_role_ids = hidden_roles.pluck(:id)
    
    (system_roles + custom_company_roles).reject { |role| hidden_role_ids.include?(role.id) }
  end
  
  # Check if a specific system role is hidden for this company
  def role_hidden?(role_id)
    hidden_roles.exists?(id: role_id)
  end
  
  # Hide a system role for this company
  def hide_role!(role_id)
    role = Role.find(role_id)
    return false unless role.is_system_role?
    
    company_hidden_roles.find_or_create_by!(role: role)
    true
  rescue ActiveRecord::RecordNotFound
    false
  end
  
  # Unhide a system role for this company
  def unhide_role!(role_id)
    company_hidden_roles.where(role_id: role_id).destroy_all
    true
  end
  
  # Get role by key (handles both system and custom roles)
  def role_by_key(role_key)
    # First check system roles
    system_role = Role.find_by(role_key: role_key, is_system_role: true)
    return system_role if system_role && !role_hidden?(system_role.id)
    
    # Then check custom company roles
    roles.find_by(role_key: role_key, is_deleted: false)
  end
  
  # Payment gateway configuration
  def external_payments_enabled?
    external_payments_id.present?
  end
  
  def payment_gateway_configured?
    external_payments_enabled?
  end
  
  # Create default location after company creation
  def create_default_location
    Rails.logger.info "🏢 [Company#create_default_location] Creating default location for Company #{id} (#{name})"
    
    location = locations.create!(
      name: 'Main Location',
      is_default: true,
      active: true,
      timezone: 'America/New_York'  # Default timezone
    )
    
    Rails.logger.info "✅ [Company#create_default_location] Successfully created location: #{location.name} (ID: #{location.id})"
    location
  rescue => e
    Rails.logger.error "❌ [Company#create_default_location] Failed to create default location for Company #{id}: #{e.message}"
    Rails.logger.error "   Validation errors: #{e.record.errors.full_messages.join(', ')}" if e.respond_to?(:record) && e.record
    Rails.logger.error e.backtrace.first(5).join("\n")
    nil
  end
  
  # Default location
  def default_location
    locations.find_by(is_default: true) || locations.first
  end
  
  # Soft delete
  def soft_delete!
    update!(
      deleted_at: Time.current,
      status: 'cancelled',
      subdomain: "deleted-#{id}-#{subdomain}",
      custom_domain: nil
    )
  end
  
  def restore!
    update!(
      deleted_at: nil,
      status: 'active'
    )
  end
  
  # Search
  def self.search(query)
    return all if query.blank?
    
    where(
      'name ILIKE ? OR subdomain ILIKE ? OR custom_domain ILIKE ?',
      "%#{query}%", "%#{query}%", "%#{query}%"
    )
  end
  
  # Module Access Methods
  def module_access
    @module_access ||= ModuleAccessService.new(self)
  end
  
  def has_module?(module_key)
    module_access.has_module?(module_key)
  end
  
  def enabled_modules
    module_access.enabled_modules
  end
  
  def modules_with_status
    module_access.modules_with_status
  end
  
  # Get current subscription plan
  def current_plan
    tenant_subscription&.subscription_plan
  end
  
  def current_plan_name
    current_plan&.display_name || subscription_tier&.titleize || 'No Plan'
  end
  
  # Subscription management helpers
  def can_add_user?
    return true if subscription_tier == 'enterprise'
    return true if max_users.nil?
    
    active_users_count < max_users
  end
  
  def can_add_location?
    return true if subscription_tier == 'enterprise'
    return true if max_locations.nil?
    
    locations_count < max_locations
  end
  
  def remaining_user_slots
    return Float::INFINITY if subscription_tier == 'enterprise'
    return Float::INFINITY if max_users.nil?
    
    max_users - active_users_count
  end
  
  def remaining_location_slots
    return Float::INFINITY if subscription_tier == 'enterprise'
    return Float::INFINITY if max_locations.nil?
    
    max_locations - locations_count
  end
  
  # Fiscal Year Helper Methods
  # Returns the fiscal year for a given date
  def fiscal_year(date = Date.current)
    if date.month >= fiscal_year_start_month
      date.year
    else
      date.year - 1
    end
  end
  
  # Returns the fiscal quarter (1-4) for a given date
  def fiscal_quarter(date = Date.current)
    months_since_fy_start = (date.month - fiscal_year_start_month) % 12
    (months_since_fy_start / 3) + 1
  end
  
  # Returns start and end dates for a fiscal quarter
  # quarter: 1-4, year: fiscal year
  def fiscal_quarter_dates(quarter, year = fiscal_year)
    raise ArgumentError, "Quarter must be 1-4" unless (1..4).include?(quarter)
    
    # Calculate start month (Q1 starts at fiscal_year_start_month)
    start_month = fiscal_year_start_month + ((quarter - 1) * 3)
    
    # Adjust if start_month goes beyond December
    if start_month > 12
      start_month -= 12
      start_year = year + 1
    else
      start_year = year
    end
    
    start_date = Date.new(start_year, start_month, 1)
    end_date = start_date.end_of_month + 2.months
    
    { start_date: start_date, end_date: end_date }
  end
  
  # Returns the month name for fiscal_year_start_month
  def fiscal_year_start_month_name
    Date::MONTHNAMES[fiscal_year_start_month]
  end
  
  # ====================
  # Public Inventory Methods
  # ====================
  
  # Generate public inventory token for secure access
  def generate_public_inventory_token
    self.public_inventory_token = SecureRandom.urlsafe_base64(32)
  end
  
  # Set default public inventory settings on company creation
  def set_default_public_inventory_settings
    # Only set defaults if public_inventory_settings is blank/nil
    return if public_inventory_settings.present?
    
    self.public_inventory_settings = {}
    self.public_inventory_enabled = false  # Disabled by default
    self.public_statuses = ['available', 'available_to_order']  # Include both statuses
    self.show_pricing = true
    self.show_contact_button = true
    self.contact_button_text = 'Request Info'
    self.require_approval = false
    self.items_per_page = 12
    self.default_layout = 'grid'
    self.show_filters = true
  end
  
  # Regenerate public inventory token (for security)
  def regenerate_public_inventory_token!
    generate_public_inventory_token
    save!
  end
  
  # Check if public inventory is enabled
  def public_inventory_enabled?
    public_inventory_enabled == true || public_inventory_enabled == 'true'
  end
  
  # Hierarchical branding resolution: Website → Location → Company
  # @param website [Website, nil] - If inventory is embedded in a website
  # @param location [Location, nil] - If inventory is location-specific
  # @return [Hash] Branding settings with logo, colors, fonts
  def resolve_branding_for_inventory(website: nil, location: nil)
    branding = {}
    
    # Priority 1: Website branding (if embedded in website)
    if website.present?
      website_settings = website.branding_settings || {}
      branding.merge!(website_settings) if website_settings.any?
    end
    
    # Priority 2: Location branding (fallback)
    if location.present? && branding.blank?
      location_settings = Setting.get('Location', location.id, 'branding') || {}
      branding.merge!(location_settings) if location_settings.any?
    end
    
    # Priority 3: Company branding (final fallback)
    if branding.blank?
      company_settings = Setting.get('Company', id, 'branding') || {}
      branding.merge!(company_settings)
    end
    
    # Ensure required branding fields have defaults
    branding[:logo] ||= logo
    branding[:primary_color] ||= '#3b82f6'  # Default blue
    branding[:company_name] ||= name
    
    branding
  end
  
  # Get public inventory URL
  def public_inventory_url(filters = {})
    return nil unless public_inventory_enabled?
    
    base_url = Rails.env.production? ? 
      "https://#{primary_domain}" : 
      "https://localhost:5173"
    
    query_params = { token: public_inventory_token }.merge(filters)
    "#{base_url}/public/inventory?#{query_params.to_query}"
  end
  
  # Get inventory embed code (iframe)
  def inventory_embed_code(filters = {}, options = {})
    return nil unless public_inventory_enabled?
    
    width = options[:width] || '100%'
    height = options[:height] || '800'
    url = public_inventory_url(filters)
    
    <<~HTML
      <iframe 
        src="#{url}"
        width="#{width}"
        height="#{height}"
        frameborder="0"
        style="border: 1px solid #e5e7eb; border-radius: 8px;"
      ></iframe>
    HTML
  end
end
