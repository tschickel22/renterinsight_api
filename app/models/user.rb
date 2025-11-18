# frozen_string_literal: true

class User < ApplicationRecord
  has_secure_password
  
  # Associations
  belongs_to :company, optional: true
  has_many :activities, dependent: :nullify
  has_many :reminders, dependent: :destroy
  has_many :user_locations, dependent: :destroy
  has_many :locations, through: :user_locations

  # RBAC System Associations
  has_many :user_role_assignments, dependent: :destroy
  has_many :roles, through: :user_role_assignments

  validates :email, presence: true, uniqueness: true
  validates :first_name, presence: true, if: -> { name.blank? }
  validates :password, length: { minimum: 6 }, if: -> { password.present? }
  
  # Virtual attribute for full name (backward compatibility with 'name' field)
  def name
    if first_name.present? && last_name.present?
      "#{first_name} #{last_name}"
    else
      read_attribute(:name) || first_name || last_name || email
    end
  end
  
  # Status helpers
  def inactive?
    status == 'inactive'
  end
  
  def suspended?
    status == 'suspended'
  end
  
  def active?
    status == 'active'
  end
  
  # Legacy Role helpers (kept for backward compatibility)
  def admin?
    role == 'admin' || role == 'super_admin'
  end
  
  def tenant?
    role == 'tenant'
  end
  
  def super_admin?
    role == 'super_admin'
  end
  
  def client?
    role == 'client' || role == 'buyer'
  end
  
  def staff?
    role == 'staff' || role == 'employee'
  end

  # RBAC System Methods
  
  # Check if user's company uses RBAC system
  def uses_rbac?
    company&.use_rbac_system || false
  end

  # Permission check delegation
  def can?(resource_key, action_key, scope_key = 'all', context = {})
    return false unless uses_rbac?
    permission_service.can?(resource_key, action_key, scope_key, context)
  end

  # Check if user has a specific role
  def has_role?(role_key, tier = nil)
    query = roles.where(key: role_key)
    query = query.where(tier: tier) if tier
    query.exists?
  end

  # Check if user is a company admin (RBAC)
  def company_admin?
    return false unless uses_rbac?
    roles.exists?(key: 'company_admin', tier: 'company')
  end

  # Get all locations accessible to this user
  def accessible_locations
    return company.locations if admin? || company_admin?
    
    # Direct location assignments only (regions not implemented yet)
    direct_location_ids = user_role_assignments
      .where(tier: 'location')
      .pluck(:location_id)
    
    Location.where(id: direct_location_ids.uniq)
  end

  # Get all regions accessible to this user
  def accessible_regions
    return [] unless admin? || company_admin?
    
    # Regions not implemented yet - return empty array
    []
  end

  private

  def permission_service
    @permission_service ||= PermissionService.new(self)
  end
end
