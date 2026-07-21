# frozen_string_literal: true

class ApiKey < ApplicationRecord
  # Associations
  belongs_to :company, optional: true  # NULL = platform-level key
  belongs_to :created_by_user, class_name: "User", foreign_key: "created_by_user_id"

  # Validations
  validates :name, presence: true
  validates :key, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: { in: %w[active revoked] }
  validates :rate_limit, numericality: { greater_than: 0 }
  validate :validate_permissions, if: -> { permissions.present? }

  # Scopes
  scope :active, -> { where(status: "active") }
  scope :revoked, -> { where(status: "revoked") }
  scope :platform_level, -> { where(company_id: nil) }
  scope :company_scoped, -> { where.not(company_id: nil) }

  # Callbacks
  before_validation :generate_key, on: :create
  
  # ==================== AUTOMATED API SCOPE GENERATION ====================
  # Auto-generate available resources from the resources table
  # This eliminates need to manually update when adding new modules
  
  # Returns array of available resources with their permissions
  # Format: [{ resource: 'leads', name: 'Leads', actions: ['read', 'write', 'delete'] }, ...]
  def self.available_resources
    Resource.active.order(:position, :name).map do |resource|
      {
        resource: resource.key,
        name: resource.name,
        actions: %w[read write delete]  # Standard CRUD permissions
      }
    end
  end
  
  # Returns flattened list of all valid resource:action combinations
  # Used for validation and frontend display
  def self.valid_permission_keys
    available_resources.flat_map do |res|
      res[:actions].map { |action| "#{res[:resource]}:#{action}" }
    end
  end

  # Scope helpers
  def platform_level?
    company_id.nil?
  end

  def company_scoped?
    company_id.present?
  end

  # Instance methods
  def active?
    status == "active"
  end

  def revoked?
    status == "revoked"
  end

  def revoke!
    update!(status: "revoked")
  end

  def touch_usage!
    update_columns(last_used_at: Time.current, request_count: request_count + 1)
  end

  # "write" is a superset that implies create + update + delete on the resource.
  # This matches the two-toggle UX (Read / Write) the API Keys tab surfaces —
  # dealers picking "Write" reasonably expect to be able to POST/PATCH/DELETE,
  # not just some undefined subset. If someone stores the finer-grained action
  # strings directly ("create", "update", "delete"), those still match too.
  WRITE_ACTIONS = %w[create update delete].freeze

  def has_permission?(resource, action)
    return true if permissions.blank? || permissions.empty?

    resource_perms = permissions[resource.to_s]
    return false if resource_perms.blank?

    action_str = action.to_s
    return true if resource_perms.include?(action_str)
    return true if resource_perms.include?('write') && WRITE_ACTIONS.include?(action_str)

    false
  end

  def rate_limit_key
    "api_key:#{id}:rate_limit"
  end

  private

  def generate_key
    self.key = "ri_live_#{SecureRandom.hex(24)}" if key.blank?
  end
  
  # Validate that all permission resources exist in resources table
  def validate_permissions
    return if permissions.blank?
    
    valid_resources = Resource.active.pluck(:key)
    invalid = permissions.keys - valid_resources
    
    if invalid.any?
      errors.add(:permissions, "references invalid resources: #{invalid.join(', ')}")
    end
  end
end
