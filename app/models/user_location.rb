# frozen_string_literal: true

class UserLocation < ApplicationRecord
  # Associations
  belongs_to :user
  belongs_to :location
  belongs_to :company

  # Validations
  validates :user_id, presence: true, uniqueness: { scope: :location_id }
  validates :location_id, presence: true
  validates :company_id, presence: true
  validates :location_role, presence: true, 
            inclusion: { in: %w[location_admin location_manager location_staff] }

  # Scopes
  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :for_user, ->(user_id) { where(user_id: user_id, active: true) }
  scope :for_location, ->(location_id) { where(location_id: location_id, active: true) }
  scope :for_company, ->(company_id) { where(company_id: company_id, active: true) }
  scope :admins, -> { where(location_role: 'location_admin', active: true) }
  scope :managers, -> { where(location_role: 'location_manager', active: true) }
  scope :staff, -> { where(location_role: 'location_staff', active: true) }

  # Callbacks
  before_validation :set_company_id, on: :create

  # Role helpers
  def admin?
    location_role == 'location_admin'
  end

  def manager?
    location_role == 'location_manager'
  end

  def staff?
    location_role == 'location_staff'
  end

  def can_manage_users?
    admin?
  end

  def can_manage_settings?
    admin?
  end

  def can_manage_operations?
    admin? || manager?
  end

  private

  def set_company_id
    self.company_id ||= location&.company_id
  end
end
