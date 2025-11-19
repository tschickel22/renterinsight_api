# frozen_string_literal: true

# Role Model
# 
# Represents a configurable role that can be assigned to users.
# Roles can be platform defaults (company_id = NULL, is_system_role = true)
# or company-specific custom roles.
# 
# Tiers:
# - company: Company-wide role
# - region: Region-specific role
# - location: Location-specific role

class Role < ApplicationRecord
  # Associations
  belongs_to :company, optional: true
  has_many :role_permissions, dependent: :destroy
  has_many :resources, through: :role_permissions
  has_many :actions, through: :role_permissions
  has_many :scopes, through: :role_permissions
  has_many :user_role_assignments, dependent: :destroy
  has_many :users, through: :user_role_assignments
  has_many :company_hidden_roles, dependent: :destroy
  has_many :companies_hidden_from, through: :company_hidden_roles, source: :company

  # Validations
  validates :tier, presence: true, inclusion: { in: %w[company region location] }
  validates :key, presence: true, length: { maximum: 100 }
  validates :name, presence: true
  validates :key, uniqueness: { scope: [:company_id, :tier] }

  # Scopes
  scope :active, -> { where(active: true) }
  scope :system_roles, -> { where(is_system_role: true, company_id: nil) }
  scope :custom_roles, -> { where(is_system_role: false).where.not(company_id: nil) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :for_tier, ->(tier) { where(tier: tier) }
  scope :company_tier, -> { where(tier: 'company') }
  scope :region_tier, -> { where(tier: 'region') }
  scope :location_tier, -> { where(tier: 'location') }

  # Callbacks
  after_save :invalidate_permission_cache
  after_destroy :invalidate_permission_cache

  # Instance methods
  def system_role?
    is_system_role && company_id.nil?
  end

  def custom_role?
    !is_system_role && company_id.present?
  end

  def hidden_for_company?(company_id)
    CompanyHiddenRole.role_hidden_for_company?(company_id, id)
  end

  def visible_for_company?(company_id)
    !hidden_for_company?(company_id)
  end

  def has_permission?(resource_key, action_key, scope_key = 'all')
    role_permissions.joins(:resource, :action, :scope).exists?(
      resources: { key: resource_key },
      actions: { key: action_key },
      scopes: { key: scope_key },
      granted: true
    )
  end

  def grant_permission!(resource_key, action_key, scope_key = 'all')
    resource = Resource.find_by!(key: resource_key)
    action = Action.find_by!(key: action_key)
    scope = Scope.find_by!(key: scope_key)

    role_permissions.find_or_create_by!(
      resource: resource,
      action: action,
      scope: scope
    ) do |permission|
      permission.granted = true
    end
  end

  def revoke_permission!(resource_key, action_key, scope_key = 'all')
    resource = Resource.find_by!(key: resource_key)
    action = Action.find_by!(key: action_key)
    scope = Scope.find_by!(key: scope_key)

    permission = role_permissions.find_by(
      resource: resource,
      action: action,
      scope: scope
    )

    permission&.update!(granted: false)
  end

  # Class methods
  def self.seed_defaults
    return if system_roles.any?

    # Company-level system roles
    company_admin = create_system_role!(
      tier: 'company',
      key: 'company_admin',
      name: 'Company Administrator',
      description: 'Full access to all company resources and settings',
      color: '#ef4444'
    )

    company_manager = create_system_role!(
      tier: 'company',
      key: 'company_manager',
      name: 'Company Manager',
      description: 'Operational control with assigned region/location access',
      color: '#f97316'
    )

    company_staff = create_system_role!(
      tier: 'company',
      key: 'company_staff',
      name: 'Company Staff',
      description: 'Standard user with assigned location access',
      color: '#3b82f6'
    )

    company_read_only = create_system_role!(
      tier: 'company',
      key: 'company_read_only',
      name: 'Read-Only User',
      description: 'View-only access to assigned areas',
      color: '#6b7280'
    )

    # Location-level system roles
    location_admin = create_system_role!(
      tier: 'location',
      key: 'location_admin',
      name: 'Location Administrator',
      description: 'Full control over assigned locations',
      color: '#8b5cf6'
    )

    location_manager = create_system_role!(
      tier: 'location',
      key: 'location_manager',
      name: 'Location Manager',
      description: 'Operational control at assigned locations',
      color: '#06b6d4'
    )

    location_staff = create_system_role!(
      tier: 'location',
      key: 'location_staff',
      name: 'Location Staff',
      description: 'Standard staff access at assigned locations',
      color: '#10b981'
    )

    # Grant permissions to Company Admin (full access to everything)
    grant_full_permissions!(company_admin)

    # Grant permissions to other roles
    grant_manager_permissions!(company_manager)
    grant_staff_permissions!(company_staff)
    grant_read_only_permissions!(company_read_only)
    grant_location_admin_permissions!(location_admin)
    grant_location_manager_permissions!(location_manager)
    grant_location_staff_permissions!(location_staff)
  end

  private

  def self.create_system_role!(attributes)
    create!(
      company_id: nil,
      is_system_role: true,
      active: true,
      **attributes
    )
  end

  def self.grant_full_permissions!(role)
    all_scope = Scope.find_by!(key: 'all')

    Resource.active.each do |resource|
      Action.all.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: all_scope,
          granted: true
        )
      end
    end
  end

  def self.grant_manager_permissions!(role)
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')
    all_scope = Scope.find_by!(key: 'all')

    # Managers can do most operations at assigned locations
    operational_resources = Resource.where(category: ['operations', 'core'])
    operational_actions = Action.where(key: %w[create read update delete export])

    operational_resources.each do |resource|
      operational_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
    end

    # Read-only for reports
    reports_resource = Resource.find_by(key: 'reports')
    read_action = Action.find_by(key: 'read')
    RolePermission.find_or_create_by!(
      role: role,
      resource: reports_resource,
      action: read_action,
      scope: all_scope,
      granted: true
    ) if reports_resource && read_action
  end

  def self.grant_staff_permissions!(role)
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')

    # Staff can create/read/update at assigned locations
    operational_resources = Resource.where(category: 'operations')
    staff_actions = Action.where(key: %w[create read update])

    operational_resources.each do |resource|
      staff_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
    end
  end

  def self.grant_read_only_permissions!(role)
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')
    read_action = Action.find_by!(key: 'read')

    Resource.active.each do |resource|
      RolePermission.find_or_create_by!(
        role: role,
        resource: resource,
        action: read_action,
        scope: assigned_locations_scope,
        granted: true
      )
    end
  end

  def self.grant_location_admin_permissions!(role)
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')

    # Location admins have full access at their locations
    Resource.active.each do |resource|
      Action.all.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
    end
  end

  def self.grant_location_manager_permissions!(role)
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')

    # Location managers can do operations but not manage settings
    operational_resources = Resource.where(category: ['operations', 'core'])
    manager_actions = Action.where(key: %w[create read update delete export])

    operational_resources.each do |resource|
      manager_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
    end
  end

  def self.grant_location_staff_permissions!(role)
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')

    # Location staff can create/read/update operations
    operational_resources = Resource.where(category: 'operations')
    staff_actions = Action.where(key: %w[create read update])

    operational_resources.each do |resource|
      staff_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
    end
  end

  def invalidate_permission_cache
    # Clear permission cache for all users with this role
    users.each do |user|
      Rails.cache.delete_matched("permissions:#{user.id}:*")
    end
  end
end
