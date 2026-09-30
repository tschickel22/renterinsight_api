# frozen_string_literal: true

class ApiKey < ApplicationRecord
  # Associations
  belongs_to :company, optional: true  # NULL = platform-level key
  belongs_to :created_by_user, class_name: "User", foreign_key: "created_by_user_id"

  # Validations
  validates :name, presence: true
  validates :key_digest, presence: true, uniqueness: true
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

  # Only a SHA-256 digest and a display preview are persisted. The plaintext is
  # held in memory on the instance that created it, so the create endpoint can
  # hand it back exactly once. Keys are 192 random bits, so an unsalted fast
  # hash is the right tool: there is nothing to brute force.
  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  # Rows written by a release older than the digest migration have no digest
  # yet. The plaintext fallback covers them until the follow-up migration
  # clears the plaintext column, and backfills the digest on first use.
  def self.find_active_by_token(token)
    return nil if token.blank?

    active.find_by(key_digest: digest(token)) || active.find_by(key: token)&.tap do |legacy|
      legacy.update_columns(key_digest: digest(token), key_preview: preview_for(token))
    end
  end

  def self.preview_for(token)
    "#{token[0..11]}...#{token[-4..]}"
  end

  def key
    @plaintext_key
  end

  def key=(token)
    @plaintext_key = token
    self.key_digest = token.present? ? self.class.digest(token) : nil
    self.key_preview = token.present? ? self.class.preview_for(token) : nil
  end
  
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

  # A key with no permissions can do nothing. This used to be the reverse (blank
  # meant full access), so a key created with every toggle left off could read
  # and write every resource in the company.
  def has_permission?(resource, action)
    return false if permissions.blank?

    resource_perms = permissions[resource.to_s]
    return false if resource_perms.blank?

    action_str = action.to_s
    return true if resource_perms.include?(action_str)
    return true if resource_perms.include?('write') && WRITE_ACTIONS.include?(action_str)

    false
  end

  private

  def generate_key
    self.key = "ri_live_#{SecureRandom.hex(24)}" if key_digest.blank?
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
