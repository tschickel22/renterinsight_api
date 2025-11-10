# frozen_string_literal: true

class Company < ApplicationRecord
  has_many :accounts, dependent: :destroy
  has_many :contacts, dependent: :destroy
  has_many :deals, dependent: :destroy
  has_many :intake_forms, dependent: :destroy
  has_many :custom_fields, dependent: :destroy
  has_many :leads, dependent: :destroy
  has_many :vehicles, dependent: :destroy
  has_many :land_parcels, dependent: :destroy
  has_many :service_tickets, dependent: :destroy
  has_many :users, dependent: :destroy
  has_many :quotes, dependent: :destroy
  
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
  
  def verify_domain!
    update(domain_verified_at: Time.current)
  rescue => e
    Rails.logger.error "Error verifying domain for Company #{id}: #{e.message}"
    false
  end
  
  def verify_email_domain!
    update(email_domain_verified_at: Time.current)
  rescue => e
    Rails.logger.error "Error verifying email domain for Company #{id}: #{e.message}"
    false
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
  
  # Settings management (existing methods)
  def communications_settings
    setting = Setting.find_by(scope_type: 'Company', scope_id: id, key: 'communications')
    setting ? JSON.parse(setting.value) : nil
  rescue => e
    Rails.logger.error "Error loading communications_settings for Company #{id}: #{e.message}"
    nil
  end
  
  def communications_settings=(value)
    setting = Setting.find_or_initialize_by(
      scope_type: 'Company',
      scope_id: id,
      key: 'communications'
    )
    setting.value = value.to_json
    setting.save!
  rescue => e
    Rails.logger.error "Error saving communications_settings for Company #{id}: #{e.message}"
    false
  end
  
  def notifications_settings
    setting = Setting.find_by(scope_type: 'Company', scope_id: id, key: 'notifications')
    setting ? JSON.parse(setting.value) : nil
  rescue => e
    Rails.logger.error "Error loading notifications_settings for Company #{id}: #{e.message}"
    nil
  end
  
  def notifications_settings=(value)
    setting = Setting.find_or_initialize_by(
      scope_type: 'Company',
      scope_id: id,
      key: 'notifications'
    )
    setting.value = value.to_json
    setting.save!
  rescue => e
    Rails.logger.error "Error saving notifications_settings for Company #{id}: #{e.message}"
    false
  end

  def branding_settings
    setting = Setting.find_by(scope_type: 'Company', scope_id: id, key: 'branding')
    setting ? JSON.parse(setting.value) : nil
  rescue => e
    Rails.logger.error "Error loading branding_settings for Company #{id}: #{e.message}"
    nil
  end
  
  def branding_settings=(value)
    setting = Setting.find_or_initialize_by(
      scope_type: 'Company',
      scope_id: id,
      key: 'branding'
    )
    setting.value = value.to_json
    setting.save!
  rescue => e
    Rails.logger.error "Error saving branding_settings for Company #{id}: #{e.message}"
    false
  end
end
