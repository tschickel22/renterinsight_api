# frozen_string_literal: true

class Company < ApplicationRecord
  include QuickbooksIntegration
  
  has_many :accounts, dependent: :destroy
  has_many :workflow_rules, dependent: :destroy
  has_many :workflow_runs, dependent: :destroy
  has_many :workflow_events, dependent: :destroy
  has_many :workflow_approvals, dependent: :destroy
  has_many :workflow_inbound_triggers, dependent: :destroy
  has_many :workflow_ai_generations, dependent: :destroy
  has_many :reports, dependent: :destroy
  has_many :contacts, dependent: :destroy
  has_many :deals, dependent: :destroy
  has_many :lenders, dependent: :destroy
  has_many :intake_forms, dependent: :destroy
  has_many :custom_fields, dependent: :destroy
  has_many :custom_field_migrations, dependent: :destroy
  has_many :page_layouts, dependent: :destroy
  has_many :field_option_overrides, dependent: :destroy
  has_many :leads, dependent: :destroy
  has_many :vehicles, dependent: :destroy
  has_many :dealer_catalog_subscriptions, dependent: :destroy
  has_many :vehicle_invoices, dependent: :destroy
  has_many :package_templates, dependent: :destroy
  has_many :inventory_packages, through: :vehicles
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
  has_many :lead_statuses, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :facebook_integrations, dependent: :destroy
  has_many :social_accounts, dependent: :destroy
  has_many :social_posts, dependent: :destroy
  has_many :social_post_schedules, dependent: :destroy
  has_many :ad_campaigns, dependent: :destroy
  has_many :social_comments, dependent: :destroy

  # Deal Desk
  has_many :deal_desk_scenarios, dependent: :destroy
  has_many :lender_programs, dependent: :destroy
  has_many :fee_templates, dependent: :destroy
  has_many :fni_products, dependent: :destroy
  has_many :company_allowance_defaults, dependent: :destroy

  # Email Campaigns
  has_many :campaigns, dependent: :destroy
  has_many :campaign_suppressions, dependent: :destroy
  has_many :campaign_templates, dependent: :destroy
  has_many :campaign_ai_generations, dependent: :destroy
  has_many :audiences, dependent: :destroy
  has_many :audience_ai_generations, dependent: :destroy
  has_many :location_email_connections, dependent: :destroy
  has_one  :company_email_connection, dependent: :destroy
  has_many :territories, dependent: :destroy

  # Champion Integrations
  has_many :champion_lead_feed_configs, dependent: :destroy
  has_many :nurture_sequences, dependent: :destroy
  has_many :nurture_enrollments, dependent: :destroy
  has_many :tracked_links, dependent: :destroy
  
  # Finance Module Associations
  has_many :payment_methods, dependent: :destroy
  has_many :payments, dependent: :destroy
  has_many :loans, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :draw_schedule_templates, dependent: :destroy
  has_many :invoice_terms_templates, dependent: :destroy
  has_many :invoice_notes_templates, dependent: :destroy

  # Accounting Module Associations
  has_many :chart_of_accounts, dependent: :destroy
  has_many :tax_codes, dependent: :destroy
  has_many :credit_memos, dependent: :destroy
  has_many :journal_entries, dependent: :destroy
  has_many :budgets, dependent: :destroy
  has_many :budget_lines, through: :budgets
  has_many :fiscal_periods, dependent: :destroy
  has_many :account_links, dependent: :destroy
  has_many :recurring_journal_entries, dependent: :destroy
  has_one  :accounting_settings, dependent: :destroy

  # Banking & Reconciliation Associations
  has_many :bank_transactions, dependent: :destroy
  has_many :bank_rules, dependent: :destroy
  has_many :bank_reconciliations, dependent: :destroy
  has_many :recurring_bills, dependent: :destroy
  has_many :printed_checks, dependent: :destroy
  has_many :bills, dependent: :destroy
  has_many :bill_payments, dependent: :destroy
  has_many :cash_receipts, dependent: :destroy
  has_one  :quickbooks_connection, dependent: :destroy
  has_many :quickbooks_entity_mappings, dependent: :destroy
  has_many :accounting_imports, dependent: :destroy
  
  # Notifications
  has_many :notifications, dependent: :destroy

  # Tasks Module
  has_many :tasks, dependent: :destroy

  # Project Management Module
  has_many :projects, dependent: :destroy
  has_many :project_templates, dependent: :destroy
  has_many :project_phases, dependent: :destroy
  has_many :project_tasks, dependent: :destroy
  has_many :project_cost_items, dependent: :destroy
  has_many :project_material_usages, dependent: :destroy
  has_many :project_documents, dependent: :destroy

  # Vendors (unified contractors + suppliers)
  has_many :vendors, dependent: :destroy
  has_many :contractors  # alias subclass of Vendor scoped to vendor_type='contractor'
  has_many :contractor_assignments, dependent: :destroy

  # Warranty & Service Module Associations
  has_many :company_manufacturers, dependent: :destroy
  has_many :manufacturers, through: :company_manufacturers
  has_many :warranty_claims, dependent: :destroy
  has_many :manufacturer_ar_transactions, dependent: :destroy
  has_many :manufacturer_ar_payments, dependent: :destroy
  
  # Champion IMS Feed Integration
  has_many :champion_ims_retailers, dependent: :destroy
  
  # Parts & Inventory Module Associations
  has_many :part_categories, dependent: :destroy
  has_many :parts, dependent: :destroy
  has_many :suppliers  # alias subclass of Vendor scoped to vendor_type='supplier'
  has_many :purchase_orders, dependent: :destroy
  has_many :inventory_transactions, dependent: :destroy
  has_many :stock_balances, dependent: :destroy
  has_many :reorder_rules, dependent: :destroy
  # Configurator Associations
  has_many :company_floor_plans, dependent: :destroy
  has_many :floor_plans, through: :company_floor_plans
  has_many :configurations, dependent: :destroy
  has_many :company_floor_plan_option_overrides, dependent: :destroy

  # Website Builder Associations
  has_many :websites, dependent: :destroy
  # NOTE: :sites and :site_media associations removed — no Site/SiteMedia model
  # or table exists; they were dead declarations that aborted company.destroy.
  has_many :website_media, class_name: 'WebsiteMedia', dependent: :destroy  # Media for websites
  has_many :company_domains, dependent: :destroy
  # Partner API Associations
  has_many :api_keys, dependent: :destroy
  has_many :webhook_endpoints, dependent: :destroy
  # RBAC System Associations
  has_many :roles, dependent: :destroy
  has_many :company_hidden_roles, dependent: :destroy
  has_many :hidden_roles, through: :company_hidden_roles, source: :role
  
  # Twilio SMS Provisioning
  has_one :twilio_account, dependent: :destroy
  has_many :twilio_accounts, dependent: :destroy

  # Agreement & E-Sign Module
  has_many :agreement_categories, dependent: :destroy
  has_many :agreement_templates, dependent: :destroy
  has_many :agreements, dependent: :destroy

  # Subscription System Associations
  has_one :tenant_subscription, dependent: :destroy
  has_many :tenant_module_overrides, dependent: :destroy
  
  # QuickBooks Integration Associations
  has_many :quickbooks_field_mappings, dependent: :destroy
  has_many :quickbooks_sync_logs, dependent: :destroy
  has_many :activity_logs, dependent: :destroy

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
  after_create :assign_account_number
  after_create :create_default_location
  after_create :ensure_corporate_location
  after_create :seed_default_project_templates
  # MH-only: chart of accounts, Deal Desk sample config, and Max Advance allowance
  # defaults. Gated on industry == 'manufactured_housing' inside the method so RV/other
  # industries are skipped. Each sub-seed is individually rescued so one failure never
  # blocks company creation.
  after_create :seed_mh_finance_defaults
  before_create :generate_public_inventory_token
  before_create :set_default_public_inventory_settings
  # The accounting subsystem is a web of cross-referencing FKs (and a circular
  # chart_of_accounts <-> bank_accounts link, plus journal_entry_lines ->
  # chart_of_accounts marked restrict_with_error). The default
  # association-declaration order cannot satisfy those constraints, so tenant
  # deletion fails with a PG::ForeignKeyViolation. Tear the accounting tables
  # down explicitly, in FK-safe order, BEFORE the rest of the dependent: :destroy
  # cascade runs. prepend: true guarantees this fires first.
  before_destroy :purge_accounting_subsystem!, prepend: true
  
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

  # Industry classification — drives label defaults and module visibility
  INDUSTRIES = %w[manufactured_housing rv property_management storage saas].freeze
  INDUSTRY_OPTIONS = {
    'manufactured_housing' => 'Manufactured Housing',
    'rv'                   => 'RV Dealer',
    'property_management'  => 'Property Management',
    'storage'              => 'Storage',
    'saas'                 => 'SaaS / Software'
  }.freeze
  validates :industry, inclusion: { in: INDUSTRIES }
  
  # SMS Provisioning Mode
  SMS_PROVISIONING_MODES = %w[platform dedicated disabled].freeze
  validates :sms_provisioning_mode, inclusion: { in: SMS_PROVISIONING_MODES }, allow_nil: false
  
  def sms_enabled?
    sms_provisioning_mode != 'disabled'
  end
  
  def sms_dedicated?
    sms_provisioning_mode == 'dedicated'
  end
  
  def sms_platform?
    sms_provisioning_mode == 'platform'
  end
  
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
    base_domain = Rails.application.credentials.dig(:domain, :base) || Brand.current.subdomain_root
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
  # The Company Settings UI (CompanySettingsController) persists operational settings under
  # the 'operational_settings' key. Prefer that; fall back to the legacy 'operational' key
  # for any older data. (Previously this read only 'operational', which the UI never writes,
  # so it returned {} for every UI-configured company.)
  def operational_settings
    @operational_settings ||= Setting.get('Company', id, 'operational_settings').presence ||
                              Setting.get('Company', id, 'operational') ||
                              {}
  end

  # Timezone used for campaign send-window scheduling (Messaging::SendWindowCalculator).
  # Stored as an IANA name (e.g. "America/Denver"), which ActiveSupport#in_time_zone accepts.
  # Falls back to Eastern when unset.
  def time_zone
    operational_settings['timezone'].presence || 'America/New_York'
  end

  # --- Inventory sharing groups -------------------------------------------
  # Two locations under the same dealer can share a physical lot and sell
  # each other's inventory. A "sharing group" is the unit of cross-location
  # visibility — any location in a group sees inventory from every other
  # location in that group, in dropdowns, lists, stats, exports, and
  # single-vehicle fetches.
  #
  # Stored as one Setting key on the Company so a single read serves every
  # vehicle query in the request:
  #   [{ "id" => "grp_<rand>", "name" => "Lafayette Lots",
  #      "location_ids" => [77, 92] }, ...]
  def inventory_sharing_groups
    @inventory_sharing_groups ||= begin
      raw = Setting.get('Company', id, 'inventory_sharing_groups')
      raw.is_a?(Array) ? raw.map(&:deep_stringify_keys) : []
    end
  end

  # Expanded set of location IDs whose inventory is visible when the user has
  # `location_id` selected. Includes the location itself plus every peer in
  # any group containing it. Returns `[]` for a blank input so callers can
  # safely chain into a WHERE.
  def inventory_visible_location_ids(location_id)
    return [] if location_id.blank?
    loc_id = location_id.to_i
    peers = inventory_sharing_groups.flat_map do |g|
      ids = Array(g['location_ids']).map(&:to_i)
      ids.include?(loc_id) ? ids : []
    end
    ([loc_id] + peers).uniq
  end

  # Expand an array of location IDs into the union of every sharing-group
  # peer for each one. Used to extend RBAC's accessible_location_ids so a
  # location-tier user assigned to Evangeline can still see Homes To Geaux
  # inventory through the sharing group.
  def expand_with_inventory_peers(location_ids)
    return [] if location_ids.blank?
    base = Array(location_ids).map(&:to_i)
    (base + base.flat_map { |id| inventory_visible_location_ids(id) }).uniq
  end

  # Rewrite the sharing-group setting so `location_id` ends up grouped with
  # exactly `peer_ids` (symmetric — editing either side produces the same
  # final group). Removes the location from any pre-existing group; deletes
  # groups left with fewer than two members.
  def set_inventory_sharing_for_location!(location_id, peer_ids)
    loc_id = location_id.to_i
    peers = Array(peer_ids).map(&:to_i).reject { |id| id == loc_id || id <= 0 }.uniq

    # Remove this location from any group it currently belongs to, preserving
    # the other members. (We don't want to delete the whole group out from
    # under its other members when this location moves to a different group.)
    groups = inventory_sharing_groups.map do |g|
      members = Array(g['location_ids']).map(&:to_i) - [loc_id]
      g.merge('location_ids' => members)
    end

    if peers.any?
      members = ([loc_id] + peers).uniq
      existing = groups.find { |g| (Array(g['location_ids']).map(&:to_i) & peers).any? }
      if existing
        existing['location_ids'] = (Array(existing['location_ids']).map(&:to_i) + members).uniq
      else
        groups << {
          'id' => "grp_#{SecureRandom.hex(4)}",
          'name' => nil,
          'location_ids' => members
        }
      end
    end

    groups = groups.reject { |g| Array(g['location_ids']).map(&:to_i).uniq.size < 2 }
    Setting.set('Company', id, 'inventory_sharing_groups', groups)
    @inventory_sharing_groups = nil
    groups
  end

  # --- Pipeline stages ----------------------------------------------------
  # Single source of truth for deal pipeline stages. Used by Deal stage
  # validation and lead conversion so they never diverge from what the
  # company actually configured in Settings.
  DEFAULT_PIPELINE_STAGES = [
    { 'key' => 'prospecting',    'name' => 'Prospecting',    'order' => 0 },
    { 'key' => 'qualification',  'name' => 'Qualification',  'order' => 1 },
    { 'key' => 'needs_analysis', 'name' => 'Needs Analysis', 'order' => 2 },
    { 'key' => 'proposal',       'name' => 'Proposal',       'order' => 3 },
    { 'key' => 'negotiation',    'name' => 'Negotiation',    'order' => 4 },
    { 'key' => 'closed_won',     'name' => 'Closed Won',     'order' => 5 },
    { 'key' => 'closed_lost',    'name' => 'Closed Lost',    'order' => 6 }
  ].freeze

  # Resolved stages: the company's saved override, else the system default.
  def pipeline_stages
    saved = Setting.get('Company', id, 'pipeline_stages', nil)
    saved.is_a?(Array) && saved.any? ? saved : DEFAULT_PIPELINE_STAGES
  end

  # All defined stage keys (downcased). These are the only valid Deal stages.
  def pipeline_stage_keys
    pipeline_stages.map { |s| (s['key'] || s[:key]).to_s.downcase }.reject(&:blank?)
  end

  def valid_pipeline_stage?(stage)
    stage.present? && pipeline_stage_keys.include?(stage.to_s.downcase)
  end

  # Fallback win-probabilities for the system default stages (custom stages
  # carry their own 'probability' in the saved config).
  DEFAULT_STAGE_PROBABILITIES = {
    'prospecting' => 20, 'qualification' => 30, 'needs_analysis' => 40,
    'proposal' => 60, 'negotiation' => 80, 'closed_won' => 100, 'closed_lost' => 0
  }.freeze

  # Configured win-probability for a stage key, or nil if it can't be resolved.
  # Probability is derived from the stage (never user-entered), so Deal mirrors
  # this whenever its stage changes.
  def pipeline_stage_probability(stage_key)
    return nil if stage_key.blank?
    key = stage_key.to_s.downcase
    stage = pipeline_stages.find { |s| (s['key'] || s[:key]).to_s.downcase == key }
    if stage
      prob = stage['probability'] || stage[:probability]
      return prob.to_i unless prob.nil?
    end
    DEFAULT_STAGE_PROBABILITIES[key]
  end

  # Tenant-aware stage classification. Probability drives resolution
  # (100 = won, 0 = lost) so custom pipelines like Evangeline's 'won'/'lost'
  # keys don't silently fall through. Legacy default keys are always included
  # as a safety net for tenants that still use them or have no saved config.
  def won_stage_keys
    @won_stage_keys ||= (pipeline_stage_keys.select { |k| pipeline_stage_probability(k).to_i == 100 } | ['closed_won']).freeze
  end

  def lost_stage_keys
    @lost_stage_keys ||= (pipeline_stage_keys.select { |k| pipeline_stage_probability(k).to_i == 0 } | ['closed_lost']).freeze
  end

  def closed_deal_stage_keys
    @closed_deal_stage_keys ||= (won_stage_keys | lost_stage_keys).freeze
  end

  # The stage key to WRITE when calling Deal#mark_as_won / mark_as_lost.
  # Prefer the tenant's own custom key; fall back to the canonical legacy key
  # for tenants who kept the default.
  def default_won_stage_key
    (won_stage_keys - ['closed_won']).first || 'closed_won'
  end

  def default_lost_stage_key
    (lost_stage_keys - ['closed_lost']).first || 'closed_lost'
  end

  # Stage a freshly-converted deal should land in: the first stage explicitly
  # marked active (by order), falling back to the first defined stage when no
  # stage carries an active flag (legacy/default configs). Always returns a
  # key that passes Deal stage validation.
  def default_deal_stage
    ordered = pipeline_stages.sort_by { |s| (s['order'] || s[:order] || 0).to_i }
    active = ordered.find { |s| [true, 'true'].include?(s['active'] || s[:active]) }
    chosen = active || ordered.first
    chosen && (chosen['key'] || chosen[:key]).to_s.downcase
  end

  # --- Deal Desk settings -------------------------------------------------
  # Tunable per company (no code change). Stored in the deal_desk_settings jsonb column,
  # merged over these defaults.
  DEAL_DESK_SETTING_DEFAULTS = {
    'price_band_mode'   => 'amount',  # 'amount' (±$) or 'percent' (±%)
    'price_band_amount' => 15_000,    # ±$15k
    'price_band_pct'    => 10,        # ±10%
    'validity_days'     => 30,        # scenario validity window
    'days_on_lot_tiers' => [90, 120, 180]
  }.freeze

  def deal_desk_settings_resolved
    DEAL_DESK_SETTING_DEFAULTS.merge((deal_desk_settings || {}).compact)
  end

  def deal_desk_scenario_validity_days
    deal_desk_settings_resolved['validity_days'].to_i
  end

  def deal_desk_price_band
    s = deal_desk_settings_resolved
    { mode: s['price_band_mode'], amount: s['price_band_amount'].to_f, pct: s['price_band_pct'].to_f }
  end

  def deal_desk_days_on_lot_tiers
    Array(deal_desk_settings_resolved['days_on_lot_tiers']).map(&:to_i).sort
  end

  # Deal Desk write-back timing.
  #   'on_close' (default) — the selected scenario is written back to the deal
  #                          automatically inside the deal-close -> GL-approval pipeline,
  #                          so the GL post sees the desked figures.
  #   'on_apply'           — write-back stays manual (the apply endpoint only).
  # Stored as a Company Setting (mirrors operational_settings/branding), NOT a column. An
  # unrecognized stored value falls back to the safe 'on_close' default.
  WRITEBACK_MODES = %w[on_apply on_close].freeze

  def deal_desk_writeback_mode
    mode = Setting.get('Company', id, 'deal_desk_writeback_mode').presence || 'on_close'
    WRITEBACK_MODES.include?(mode) ? mode : 'on_close'
  end

  # Default finance APR (whole-number percent). Single source of truth for the rate
  # resolver's company-default tier. Reads loan_settings (set by the Company Settings UI),
  # falling back to the platform default. Replaces the value previously hardcoded in
  # CompanySettingsController#show_loan.
  DEFAULT_FINANCE_RATE = 8.0

  def default_finance_rate
    rate = (loan_settings || {})['default_interest_rate']
    rate.presence ? rate.to_f : DEFAULT_FINANCE_RATE
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
  def seed_default_project_templates
    ProjectTemplate.seed_defaults!(self)
    Rails.logger.info "✅ [Company#seed_default_project_templates] Seeded default project templates for Company #{id} (#{name})"
  rescue => e
    Rails.logger.error "❌ [Company#seed_default_project_templates] Failed to seed templates for Company #{id}: #{e.message}"
    nil
  end

  # MH-only finance bootstrap (chart of accounts + Max Advance allowance defaults). Runs
  # automatically for every new manufactured_housing company. Idempotent and each piece is
  # rescued independently so a failure in one never aborts company creation or the others.
  #
  # NOTE: Deal Desk sample config is intentionally NOT seeded here — it's placeholder rate
  # sheets and flips the gated module on, so it belongs in the demo-company seed only
  # (db/seeds/demo_company.rb), not on real new companies.
  #
  # This seeds ONLY per-company data. The global RBAC catalog (Resource/Action/Role
  # seed_defaults) is seeded once per environment, not here.
  def seed_mh_finance_defaults
    return unless industry == 'manufactured_housing'

    # 1. Chart of Accounts (idempotent MH chart).
    begin
      require Rails.root.join('db/seeds/seed_default_chart_of_accounts').to_s
      DefaultChartOfAccountsSeeder.seed(self)
      Rails.logger.info "✅ [Company#seed_mh_finance_defaults] COA seeded for Company #{id}"
    rescue => e
      Rails.logger.error "❌ [Company#seed_mh_finance_defaults] COA failed for Company #{id}: #{e.message}"
    end

    # 2. Max Advance company allowance defaults (21st Mortgage-derived). Lenders created
    #    afterward inherit these via Lender#after_create automatically.
    begin
      CompanyAllowanceDefault.seed_defaults(self)
      Rails.logger.info "✅ [Company#seed_mh_finance_defaults] Allowance defaults seeded for Company #{id}"
    rescue => e
      Rails.logger.error "❌ [Company#seed_mh_finance_defaults] Allowance defaults failed for Company #{id}: #{e.message}"
    end

    nil
  end

  def ensure_corporate_location
    Location.ensure_corporate_for(self)
  rescue => e
    Rails.logger.warn "[Company] Failed to create corporate location for company #{id}: #{e.message}"
  end

  # Assign account number derived from id (RI-00019). Runs after_create because
  # id isn't available until the row exists. update_column skips validations and
  # callbacks so it won't re-trigger this hook.
  # Deletes every accounting-module record for this company in dependency order
  # (leaf referencers first, core tables last) so a tenant can be destroyed
  # without tripping a foreign-key constraint. Uses delete_all for speed; the
  # whole thing runs inside the destroy transaction, so it is atomic with the
  # rest of the cascade. Line tables (no company_id) are scoped via their parent.
  def purge_accounting_subsystem!
    cid          = id
    bill_ids     = Bill.where(company_id: cid).select(:id)
    budget_ids   = Budget.where(company_id: cid).select(:id)
    je_ids       = JournalEntry.where(company_id: cid).select(:id)
    recon_ids    = BankReconciliation.where(company_id: cid).select(:id)

    # 1. Outermost referencers (point at bills / journal_entries / bank_accounts).
    PrintedCheck.where(company_id: cid).delete_all
    CashReceipt.where(company_id: cid).delete_all   # cash_receipt_applications cascade
    BillPayment.where(company_id: cid).delete_all
    BillLineItem.where(bill_id: bill_ids).delete_all
    Bill.where(company_id: cid).delete_all
    RecurringBill.where(company_id: cid).delete_all
    BankTransaction.where(company_id: cid).delete_all
    BankRule.where(company_id: cid).delete_all
    BankReconciliationItem.where(bank_reconciliation_id: recon_ids).delete_all
    BankReconciliation.where(company_id: cid).delete_all
    BudgetLine.where(budget_id: budget_ids).delete_all
    Budget.where(company_id: cid).delete_all
    JournalEntryLine.where(journal_entry_id: je_ids).delete_all
    JournalEntry.where(company_id: cid).delete_all
    AccountLink.where(company_id: cid).delete_all
    AccountingSettings.where(company_id: cid).delete_all
    RecurringJournalEntry.where(company_id: cid).delete_all
    FiscalPeriod.where(company_id: cid).delete_all
    AccountingImport.where(company_id: cid).delete_all

    # 2. Break the circular chart_of_accounts <-> bank_accounts reference, then
    #    drop both. Self-referential parent_id is satisfied because each table is
    #    cleared in a single statement (NO ACTION is checked at statement end).
    BankAccount.where(company_id: cid).update_all(chart_of_account_id: nil)
    ChartOfAccount.where(company_id: cid).update_all(bank_account_id: nil)
    BankAccount.where(company_id: cid).delete_all
    ChartOfAccount.where(company_id: cid).delete_all
  end

  def assign_account_number
    return if account_number.present?
    update_column(:account_number, format('RI-%05d', id))
  rescue => e
    Rails.logger.error "Failed to assign account_number for Company #{id}: #{e.message}"
  end

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
  
  # Generate public inventory token for secure access (collision-safe)
  def generate_public_inventory_token
    return if public_inventory_token.present?
    self.public_inventory_token = loop do
      candidate = SecureRandom.urlsafe_base64(32)
      break candidate unless Company.exists?(public_inventory_token: candidate)
    end
  end

  # Set default public inventory settings on company creation
  def set_default_public_inventory_settings
    # Only set defaults if public_inventory_settings is blank/nil
    return if public_inventory_settings.present?

    self.public_inventory_settings = {}
    self.public_inventory_enabled = true  # Enabled by default so nurture email links work
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
  
  # ====================
  # Industry Label System
  # ====================

  LABEL_DEFAULTS = {
    'manufactured_housing' => {
      'vehicle'       => 'Home',
      'vehicles'      => 'Homes',
      'vin'           => 'Serial Number',
      'stock_number'  => 'Stock #',
      'make'          => 'Manufacturer',
      'model'         => 'Model Name',
      'year'          => 'Year',
      'listing_type'  => 'Home Type',
      'lot'           => 'Lot/Space',
      'bedrooms'      => 'Bedrooms',
      'bathrooms'     => 'Bathrooms',
      'sqft'          => 'Sq Ft',
      'inventory'     => 'Inventory',
      'deal'          => 'Deal',
      'deals'         => 'Deals',
      'lead'           => 'Lead',
      'leads'          => 'Leads',
      'vehicle_long'   => 'Manufactured Home',
      'vehicles_long'  => 'Manufactured Homes',
      'vin_short'      => 'Serial',
      'contact'        => 'Contact',
      'contacts'       => 'Contacts',
      'account'        => 'Account',
      'accounts'       => 'Accounts',
      'quote'          => 'Quote',
      'quotes'         => 'Quotes',
      'invoice'        => 'Invoice',
      'invoices'       => 'Invoices',
      'service_ticket' => 'Service Ticket',
      'service_tickets'=> 'Service Tickets',
      'project'        => 'Project',
      'projects'       => 'Projects'
    }.freeze,
    'rv' => {
      'vehicle'       => 'Unit',
      'vehicles'      => 'Units',
      'vin'           => 'VIN',
      'stock_number'  => 'Stock #',
      'make'          => 'Manufacturer',
      'model'         => 'Model',
      'year'          => 'Year',
      'listing_type'  => 'Unit Type',
      'lot'           => 'Space',
      'bedrooms'      => 'Sleeping Capacity',
      'bathrooms'     => 'Bathrooms',
      'sqft'          => 'Length (ft)',
      'inventory'     => 'Inventory',
      'deal'          => 'Deal',
      'deals'         => 'Deals',
      'lead'           => 'Lead',
      'leads'          => 'Leads',
      'vehicle_long'   => 'Recreational Vehicle',
      'vehicles_long'  => 'Recreational Vehicles',
      'vin_short'      => 'VIN',
      'contact'        => 'Contact',
      'contacts'       => 'Contacts',
      'account'        => 'Account',
      'accounts'       => 'Accounts',
      'quote'          => 'Quote',
      'quotes'         => 'Quotes',
      'invoice'        => 'Invoice',
      'invoices'       => 'Invoices',
      'service_ticket' => 'Service Ticket',
      'service_tickets'=> 'Service Tickets',
      'project'        => 'Project',
      'projects'       => 'Projects'
    }.freeze,
    'saas' => {
      'vehicle'       => 'Product',
      'vehicles'      => 'Products',
      'vin'           => 'SKU',
      'stock_number'  => 'Product ID',
      'make'          => 'Category',
      'model'         => 'Product Name',
      'year'          => 'Version',
      'listing_type'  => 'Product Type',
      'lot'           => 'N/A',
      'bedrooms'      => 'N/A',
      'bathrooms'     => 'N/A',
      'sqft'          => 'N/A',
      'inventory'     => 'Products',
      'deal'          => 'Opportunity',
      'deals'         => 'Opportunities',
      'lead'           => 'Prospect',
      'leads'          => 'Prospects',
      'vehicle_long'   => 'Software Product',
      'vehicles_long'  => 'Software Products',
      'vin_short'      => 'SKU',
      'contact'        => 'Contact',
      'contacts'       => 'Contacts',
      'account'        => 'Account',
      'accounts'       => 'Accounts',
      'quote'          => 'Quote',
      'quotes'         => 'Quotes',
      'invoice'        => 'Invoice',
      'invoices'       => 'Invoices',
      'service_ticket' => 'Support Ticket',
      'service_tickets'=> 'Support Tickets',
      'project'        => 'Project',
      'projects'       => 'Projects'
    }.freeze,
    'property_management' => {
      'vehicle'       => 'Unit',
      'vehicles'      => 'Units',
      'vin'           => 'Unit ID',
      'stock_number'  => 'Unit #',
      'make'          => 'Property',
      'model'         => 'Unit Type',
      'year'          => 'Year Built',
      'listing_type'  => 'Unit Type',
      'lot'           => 'Unit/Suite',
      'bedrooms'      => 'Beds',
      'bathrooms'     => 'Baths',
      'sqft'          => 'Sq Ft',
      'inventory'     => 'Properties',
      'deal'          => 'Lease',
      'deals'         => 'Leases',
      'lead'           => 'Applicant',
      'leads'          => 'Applicants',
      'vehicle_long'   => 'Rental Unit',
      'vehicles_long'  => 'Rental Units',
      'vin_short'      => 'ID',
      'contact'        => 'Contact',
      'contacts'       => 'Contacts',
      'account'        => 'Account',
      'accounts'       => 'Accounts',
      'quote'          => 'Quote',
      'quotes'         => 'Quotes',
      'invoice'        => 'Invoice',
      'invoices'       => 'Invoices',
      'service_ticket' => 'Maintenance Request',
      'service_tickets'=> 'Maintenance Requests',
      'project'        => 'Project',
      'projects'       => 'Projects'
    }.freeze,
    'storage' => {
      'vehicle'       => 'Unit',
      'vehicles'      => 'Units',
      'vin'           => 'Unit ID',
      'stock_number'  => 'Unit #',
      'make'          => 'Facility',
      'model'         => 'Unit Size',
      'year'          => 'N/A',
      'listing_type'  => 'Unit Type',
      'lot'           => 'Unit',
      'bedrooms'      => 'N/A',
      'bathrooms'     => 'N/A',
      'sqft'          => 'Sq Ft',
      'inventory'     => 'Units',
      'deal'          => 'Rental',
      'deals'         => 'Rentals',
      'lead'           => 'Inquiry',
      'leads'          => 'Inquiries',
      'vehicle_long'   => 'Storage Unit',
      'vehicles_long'  => 'Storage Units',
      'vin_short'      => 'ID',
      'contact'        => 'Contact',
      'contacts'       => 'Contacts',
      'account'        => 'Account',
      'accounts'       => 'Accounts',
      'quote'          => 'Quote',
      'quotes'         => 'Quotes',
      'invoice'        => 'Invoice',
      'invoices'       => 'Invoices',
      'service_ticket' => 'Service Request',
      'service_tickets'=> 'Service Requests',
      'project'        => 'Project',
      'projects'       => 'Projects'
    }.freeze
  }.freeze

  def label_defaults
    LABEL_DEFAULTS[industry] || LABEL_DEFAULTS['manufactured_housing']
  end

  def label_overrides
    Setting.get('Company', id, 'label_overrides') || {}
  end

  def resolved_labels
    label_defaults.merge(label_overrides)
  end

  # ==================== CONVERSION TRACKING ====================
  # Ad-platform IDs used to fire PageView + Lead conversions on public intake
  # forms. Company holds the default; a location overrides per-key. Keys are
  # camelCase to pass straight through to the frontend tracking helper.
  TRACKING_KEYS = %w[metaPixelId googleGa4Id googleAdsId googleAdsLeadLabel].freeze

  # Company-level defaults (whitelisted, blanks dropped).
  def tracking_defaults
    sanitize_tracking(tracking_settings)
  end

  # Effective config for a given location (nil => company default only).
  # Per-key: a present location value wins, else the company default.
  def resolved_tracking(location = nil)
    company_cfg = tracking_defaults
    loc_cfg = location ? sanitize_tracking(location.tracking_settings) : {}
    TRACKING_KEYS.each_with_object({}) do |key, out|
      value = loc_cfg[key].presence || company_cfg[key].presence
      out[key] = value if value
    end
  end

  # Persist the company default. Accepts a hash of TRACKING_KEYS; unknown keys
  # ignored, blanks cleared. Returns the saved (sanitized) config.
  def save_tracking_defaults(submitted)
    update!(tracking_settings: sanitize_tracking(submitted))
    tracking_defaults
  end

  # Whitelist to TRACKING_KEYS, stringify, drop blanks. Tolerates
  # ActionController params, symbol keys, and nil. Class method so Location can
  # reuse it for its overrides without duplicating the shape.
  def self.sanitize_tracking(raw)
    hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : (raw || {})
    TRACKING_KEYS.each_with_object({}) do |key, out|
      value = hash[key] || hash[key.to_sym]
      value = value.to_s.strip if value
      out[key] = value if value.present?
    end
  end

  def sanitize_tracking(raw)
    self.class.sanitize_tracking(raw)
  end

  def save_label_overrides(submitted)
    return {} if submitted.blank?

    defaults = label_defaults
    overrides = label_overrides.dup

    submitted.each do |key, value|
      key = key.to_s
      next unless defaults.key?(key)

      if value.blank? || value.to_s == defaults[key]
        overrides.delete(key)
      else
        overrides[key] = value.to_s
      end
    end

    Setting.set('Company', id, 'label_overrides', overrides)
    overrides
  end

  def clear_label_override!(key)
    overrides = label_overrides.dup
    overrides.delete(key.to_s)
    Setting.set('Company', id, 'label_overrides', overrides)
    overrides
  end

  def reset_label_overrides!
    Setting.set('Company', id, 'label_overrides', {})
    {}
  end

  # -----------------------------------------------------------------------
  # Field tooltip overrides — per-company help text for both system fields
  # and custom fields. Same shape as label_overrides but keyed by module +
  # field_key so a single lookup can serve every entity type. Custom-field
  # tooltips ALSO live on CustomField#description; this store is the source
  # of truth for tooltips on real AR columns (e.g. "leads.email") that
  # don't have a CustomField row to hang metadata on.
  #
  # Storage shape:
  #   {
  #     "leads"   => { "email" => "Primary contact email", "phone" => "..." },
  #     "deals"   => { "amount" => "Sale total including add-ons" }
  #   }
  # -----------------------------------------------------------------------

  def field_tooltip_overrides
    Setting.get('Company', id, 'field_tooltip_overrides') || {}
  end

  # Look up a single tooltip. Falls through to any custom-field description
  # stored on CustomField when no override exists — so setting a description
  # on a custom field in the CustomFieldModal automatically works as a
  # tooltip without a second write.
  def resolved_field_tooltip(module_name, field_key)
    mod = module_name.to_s
    key = field_key.to_s
    override = field_tooltip_overrides.dig(mod, key)
    return override if override.present?

    custom_fields
      .where(module: mod, field_key: key, is_active: true)
      .limit(1)
      .pick(:description)
  end

  # Save/replace a single tooltip. Blank text clears the entry so an empty
  # value in the UI resets to the shipped/CustomField default without a
  # separate delete call.
  def save_field_tooltip(module_name, field_key, text)
    mod = module_name.to_s
    key = field_key.to_s
    overrides = field_tooltip_overrides.deep_dup
    overrides[mod] ||= {}

    if text.blank?
      overrides[mod].delete(key)
      overrides.delete(mod) if overrides[mod].empty?
    else
      overrides[mod][key] = text.to_s
    end

    Setting.set('Company', id, 'field_tooltip_overrides', overrides)
    overrides
  end

  def clear_field_tooltip!(module_name, field_key)
    save_field_tooltip(module_name, field_key, nil)
  end

  def reset_field_tooltips!
    Setting.set('Company', id, 'field_tooltip_overrides', {})
    {}
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
