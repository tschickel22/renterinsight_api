# frozen_string_literal: true

class ApiKey < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :created_by_user, class_name: "User", foreign_key: "created_by_user_id"

  # Validations
  validates :name, presence: true
  validates :key, presence: true, uniqueness: true
  validates :secret_digest, presence: true
  validates :status, presence: true, inclusion: { in: %w[active revoked] }
  validates :rate_limit, numericality: { greater_than: 0 }

  # Scopes
  scope :active, -> { where(status: "active") }
  scope :revoked, -> { where(status: "revoked") }

  # Callbacks
  before_validation :generate_key_and_secret, on: :create

  # Virtual attribute - only available on creation
  attr_accessor :raw_secret

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

  def authenticate_secret(raw_secret)
    BCrypt::Password.new(secret_digest) == raw_secret
  rescue BCrypt::Errors::InvalidHash
    false
  end

  def touch_usage!
    update_columns(last_used_at: Time.current, request_count: request_count + 1)
  end

  def has_permission?(resource, action)
    return true if permissions.blank? || permissions.empty?

    resource_perms = permissions[resource.to_s]
    return false unless resource_perms

    resource_perms.include?(action.to_s)
  end

  def rate_limit_key
    "api_key:#{id}:rate_limit"
  end

  private

  def generate_key_and_secret
    self.key = "ri_live_#{SecureRandom.hex(24)}" if key.blank?

    if secret_digest.blank?
      self.raw_secret = "ri_secret_#{SecureRandom.hex(32)}"
      self.secret_digest = BCrypt::Password.create(raw_secret)
    end
  end
end
