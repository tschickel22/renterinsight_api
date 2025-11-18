# frozen_string_literal: true

# UserRoleAssignment Model
# 
# Assigns roles to users with specific tier context.
# This replaces the old User.role and UserLocation.location_role approach.
# 
# Tiers:
# - company: User has this role company-wide
# - region: User has this role for specific region(s)
# - location: User has this role for specific location(s)

class UserRoleAssignment < ApplicationRecord
  # Associations
  belongs_to :user
  belongs_to :role
  belongs_to :region, optional: true
  belongs_to :location, optional: true
  belongs_to :assigned_by, class_name: 'User', optional: true

  # Validations
  validates :user_id, presence: true
  validates :role_id, presence: true
  validates :tier, presence: true, inclusion: { in: %w[company region location] }
  
  # Tier-specific validations
  validate :validate_tier_assignment

  # Uniqueness validation
  validates :user_id, uniqueness: { 
    scope: [:role_id, :tier, :region_id, :location_id],
    message: 'already has this role assignment'
  }

  # Scopes
  scope :active, -> { where('expires_at IS NULL OR expires_at > ?', Time.current) }
  scope :expired, -> { where('expires_at IS NOT NULL AND expires_at <= ?', Time.current) }
  scope :for_user, ->(user_id) { where(user_id: user_id) }
  scope :for_role, ->(role_id) { where(role_id: role_id) }
  scope :company_tier, -> { where(tier: 'company') }
  scope :region_tier, -> { where(tier: 'region') }
  scope :location_tier, -> { where(tier: 'location') }
  scope :for_location, ->(location_id) { where(tier: 'location', location_id: location_id) }
  scope :for_region, ->(region_id) { where(tier: 'region', region_id: region_id) }

  # Callbacks
  before_validation :set_assigned_at, on: :create
  after_save :invalidate_user_cache
  after_destroy :invalidate_user_cache

  # Instance methods
  def active?
    expires_at.nil? || expires_at > Time.current
  end

  def expired?
    !active?
  end

  def company_assignment?
    tier == 'company'
  end

  def region_assignment?
    tier == 'region'
  end

  def location_assignment?
    tier == 'location'
  end

  def scope_name
    case tier
    when 'company'
      'Company-wide'
    when 'region'
      region&.name || 'Region'
    when 'location'
      location&.name || 'Location'
    end
  end

  private

  def validate_tier_assignment
    case tier
    when 'company'
      if region_id.present? || location_id.present?
        errors.add(:base, 'Company tier assignments cannot have region or location')
      end
    when 'region'
      if region_id.blank?
        errors.add(:region_id, 'must be present for region tier assignments')
      end
      if location_id.present?
        errors.add(:location_id, 'must be blank for region tier assignments')
      end
    when 'location'
      if location_id.blank?
        errors.add(:location_id, 'must be present for location tier assignments')
      end
    end
  end

  def set_assigned_at
    self.assigned_at ||= Time.current
  end

  def invalidate_user_cache
    Rails.cache.delete_matched("permissions:#{user_id}:*")
  end
end
