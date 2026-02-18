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

  # Scopes
  scope :active, -> { where(status: "active") }
  scope :revoked, -> { where(status: "revoked") }
  scope :platform_level, -> { where(company_id: nil) }
  scope :company_scoped, -> { where.not(company_id: nil) }

  # Callbacks
  before_validation :generate_key, on: :create

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

  def generate_key
    self.key = "ri_live_#{SecureRandom.hex(24)}" if key.blank?
  end
end
