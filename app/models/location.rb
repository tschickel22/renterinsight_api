# frozen_string_literal: true

class Location < ApplicationRecord
  include QuickbooksIntegration
  
  # Associations
  belongs_to :company
  has_many :user_locations, dependent: :destroy
  has_many :users, through: :user_locations
  has_many :bank_accounts, dependent: :destroy
  has_many :vehicles, dependent: :nullify
  has_many :listings, dependent: :nullify
  has_many :leads, dependent: :nullify
  has_many :deals, dependent: :nullify
  has_many :accounts, dependent: :nullify
  has_many :contacts, dependent: :nullify
  has_many :service_tickets, dependent: :nullify
  has_many :quotes, dependent: :nullify
  has_many :brochures, dependent: :nullify
  has_many :location_activities, dependent: :destroy
  
  # Warranty & Service Module Associations
  has_many :location_manufacturers, dependent: :destroy
  has_many :manufacturers, through: :location_manufacturers

  # Validations
  validates :company_id, presence: true
  validates :name, presence: true, length: { maximum: 255 }
  validates :code, length: { maximum: 10 }, uniqueness: { scope: :company_id, allow_nil: true }
  validates :timezone, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :phone, length: { maximum: 20 }, allow_blank: true
  validates :zip_code, length: { maximum: 10 }, allow_blank: true
  validates :country, length: { maximum: 2 }, allow_blank: true
  
  # Scopes
  scope :active, -> { where(active: true, is_deleted: false) }
  scope :inactive, -> { where(active: false) }
  scope :deleted, -> { where(is_deleted: true) }
  scope :for_company, ->(company_id) { where(company_id: company_id, is_deleted: false) }
  scope :by_name, -> { order(:name) }
  scope :recent, -> { order(created_at: :desc) }

  # Callbacks
  before_validation :normalize_fields
  before_validation :set_defaults, on: :create
  after_update :track_settings_changes
  
  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current, active: false)
  end

  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end

  # Settings inheritance and resolution
  # Three-tier inheritance: Location → Company → Platform defaults
  
  def resolved_branding_settings
    Rails.logger.info "=" * 80
    Rails.logger.info "Resolving branding for Location #{id}"
    Rails.logger.info "Location branding_settings: #{branding_settings.inspect}"
    
    resolved = LocationSettingsResolver.new(self).resolved_branding_settings
    
    Rails.logger.info "Resolved branding result: #{resolved.inspect}"
    Rails.logger.info "=" * 80
    
    resolved
  rescue => e
    Rails.logger.error "Error resolving branding settings for Location #{id}: #{e.message}"
    branding_settings || {}
  end

  def resolved_communication_settings
    LocationSettingsResolver.new(self).resolved_communication_settings
  rescue => e
    Rails.logger.error "Error resolving communication settings for Location #{id}: #{e.message}"
    communication_settings || {}
  end

  def resolved_operational_settings
    resolved = LocationSettingsResolver.new(self).resolved_operational_settings
    
    # Merge with location-specific data fields
    resolved.merge(
      'timezone' => timezone,
      'business_hours' => business_hours.presence || resolved['business_hours'],
      'delivery_radius_miles' => delivery_radius_miles || resolved['delivery_radius_miles'],
      'clock_format' => operational_settings&.dig('clock_format') || resolved['clock_format'] || '24'
    )
  rescue => e
    Rails.logger.error "Error resolving operational settings for Location #{id}: #{e.message}"
    operational_settings || {}
  end

  def resolved_integration_settings
    company_integration = company.integration_settings || {}
    location_integration = integration_settings || {}
    company_integration.deep_merge(location_integration)
  rescue => e
    Rails.logger.error "Error resolving integration settings for Location #{id}: #{e.message}"
    integration_settings || {}
  end

  # Check if location has specific integration enabled
  def integration_enabled?(provider)
    settings = resolved_integration_settings
    settings.dig(provider.to_s, 'enabled') == true
  rescue
    false
  end

  # Display helpers
  def display_name
    code.present? ? "#{name} (#{code})" : name
  end

  def full_address
    parts = [address_line1, address_line2, city, state, zip_code].compact.reject(&:blank?)
    parts.any? ? parts.join(', ') : nil
  end

  def address_summary
    return nil unless city && state
    [city, state].compact.join(', ')
  end

  # User assignment helpers
  def assign_user(user, role: 'location_staff', assigned_by: nil)
    user_locations.find_or_create_by!(user_id: user.id) do |ul|
      ul.company_id = company_id
      ul.location_role = role
      ul.assigned_by = assigned_by
    end
  end

  def remove_user(user)
    user_locations.find_by(user_id: user.id)&.destroy
  end

  def has_user?(user)
    user_locations.exists?(user_id: user.id, active: true)
  end

  def location_admins
    users.joins(:user_locations)
         .where(user_locations: { location_id: id, location_role: 'location_admin', active: true })
  end

  def location_staff
    users.joins(:user_locations)
         .where(user_locations: { location_id: id, active: true })
  end

  # Activity metrics
  def active_vehicles_count
    vehicles.where(is_deleted: false, status: 'available').count
  rescue
    0
  end

  def active_listings_count
    listings.where(is_deleted: false, status: 'published').count
  rescue
    0
  end

  def open_leads_count
    leads.where(status: ['new', 'contacted', 'qualified']).count
  rescue
    0
  end

  def active_deals_count
    deals.where(stage: ['qualification', 'proposal', 'negotiation']).count
  rescue
    0
  end
  
  # Zego integration helpers
  def synced_to_zego?
    external_payments_property_id.present? && 
      bank_accounts.active.any? { |ba| ba.external_id.present? }
  end
  
  def zego_ready?
    # Location is ready for Zego if it has at least one bank account configured
    bank_accounts.active.any?
  end
  
  def operating_bank_account
    bank_accounts.active.operating.first
  end
  
  def deposit_bank_account
    bank_accounts.active.deposit.first
  end

  private

  def normalize_fields
    self.name = name&.strip
    self.code = code&.strip&.upcase if code.present?
    self.email = email&.strip&.downcase if email.present?
    self.phone = phone&.strip if phone.present?
    self.city = city&.strip&.titleize if city.present?
    self.state = state&.strip&.upcase if state.present?
    self.zip_code = zip_code&.strip if zip_code.present?
    self.country = country&.strip&.upcase if country.present?
  end

  def set_defaults
    self.timezone ||= 'America/New_York'
    self.country ||= 'US'
    self.active = true if active.nil?
    self.is_deleted = false if is_deleted.nil?
    self.branding_settings ||= {}
    self.communication_settings ||= {}
    self.operational_settings ||= {}
    self.integration_settings ||= {}
    self.business_hours ||= {}
  end

  def track_settings_changes
    return unless saved_change_to_branding_settings? || 
                  saved_change_to_communication_settings? || 
                  saved_change_to_operational_settings? ||
                  saved_change_to_business_hours? ||
                  saved_change_to_timezone? ||
                  saved_change_to_delivery_radius_miles?

    user = User.find_by(id: updated_by) if updated_by.present?

    if saved_change_to_branding_settings?
      old_settings = saved_change_to_branding_settings[0] || {}
      new_settings = saved_change_to_branding_settings[1] || {}
      
      if new_settings.empty? && old_settings.present?
        LocationActivity.log_settings_cleared(
          location: self,
          category: 'branding',
          user: user
        )
      elsif new_settings.present?
        changes = calculate_setting_changes(old_settings, new_settings)
        LocationActivity.log_settings_change(
          location: self,
          category: 'branding',
          user: user,
          changes: changes
        ) if changes.any?
      end
    end

    if saved_change_to_communication_settings?
      old_settings = saved_change_to_communication_settings[0] || {}
      new_settings = saved_change_to_communication_settings[1] || {}
      
      if new_settings.empty? && old_settings.present?
        LocationActivity.log_settings_cleared(
          location: self,
          category: 'communication',
          user: user
        )
      elsif new_settings.present?
        changes = calculate_setting_changes(old_settings, new_settings)
        LocationActivity.log_settings_change(
          location: self,
          category: 'communication',
          user: user,
          changes: changes
        ) if changes.any?
      end
    end

    if saved_change_to_operational_settings?
      old_settings = saved_change_to_operational_settings[0] || {}
      new_settings = saved_change_to_operational_settings[1] || {}
      
      if new_settings.empty? && old_settings.present?
        LocationActivity.log_settings_cleared(
          location: self,
          category: 'operational',
          user: user
        )
      elsif new_settings.present?
        changes = calculate_setting_changes(old_settings, new_settings)
        LocationActivity.log_settings_change(
          location: self,
          category: 'operational',
          user: user,
          changes: changes
        ) if changes.any?
      end
    end

    # Track changes to operational column fields (business_hours, timezone, delivery_radius)
    operational_column_changes = {}
    
    if saved_change_to_business_hours?
      old_hours = saved_change_to_business_hours[0]
      new_hours = saved_change_to_business_hours[1]
      operational_column_changes['business_hours'] = { from: old_hours, to: new_hours }
    end
    
    if saved_change_to_timezone?
      old_tz = saved_change_to_timezone[0]
      new_tz = saved_change_to_timezone[1]
      operational_column_changes['timezone'] = { from: old_tz, to: new_tz }
    end
    
    if saved_change_to_delivery_radius_miles?
      old_radius = saved_change_to_delivery_radius_miles[0]
      new_radius = saved_change_to_delivery_radius_miles[1]
      operational_column_changes['delivery_radius_miles'] = { from: old_radius, to: new_radius }
    end
    
    if operational_column_changes.any?
      LocationActivity.log_settings_change(
        location: self,
        category: 'operational',
        user: user,
        changes: operational_column_changes
      )
    end
  rescue => e
    Rails.logger.error "Error tracking location settings changes: #{e.message}"
  end

  def calculate_setting_changes(old_settings, new_settings)
    changes = {}
    
    (old_settings.keys + new_settings.keys).uniq.each do |key|
      old_val = old_settings[key]
      new_val = new_settings[key]
      
      if old_val != new_val
        changes[key] = { from: old_val, to: new_val }
      end
    end
    
    changes
  end
end
