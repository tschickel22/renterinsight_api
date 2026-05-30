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

    # Specialized department roles (location-tier)
    service_tech = create_system_role!(
      tier: 'location',
      key: 'service_tech',
      name: 'Service Technician',
      description: 'Service ticket management and field operations',
      color: '#f59e0b',
      department: 'service'
    )

    sales_rep = create_system_role!(
      tier: 'location',
      key: 'sales_rep',
      name: 'Sales Representative',
      description: 'Quotes, deals, and CRM operations',
      color: '#ec4899',
      department: 'sales'
    )

    finance_staff = create_system_role!(
      tier: 'location',
      key: 'finance_staff',
      name: 'Finance Staff',
      description: 'Payments, invoices, and financial operations',
      color: '#14b8a6',
      department: 'finance'
    )

    crm_specialist = create_system_role!(
      tier: 'location',
      key: 'crm_specialist',
      name: 'CRM Specialist',
      description: 'Lead management and customer relations',
      color: '#8b5cf6',
      department: 'crm'
    )

    inventory_manager = create_system_role!(
      tier: 'location',
      key: 'inventory_manager',
      name: 'Inventory Manager',
      description: 'Inventory and operations management',
      color: '#6366f1',
      department: 'operations'
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
    
    # Grant specialized role permissions
    grant_service_tech_permissions!(service_tech)
    grant_sales_rep_permissions!(sales_rep)
    grant_finance_staff_permissions!(finance_staff)
    grant_crm_specialist_permissions!(crm_specialist)
    grant_inventory_manager_permissions!(inventory_manager)
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

  # Deal Desk grants at scope 'all' (the controller authorizes with default scope 'all';
  # location filtering is applied operationally via accessible_location_ids). Reps build/
  # quote/compare freely; configure + transfer_unit are manager-only.
  def self.grant_deal_desk!(role, action_keys)
    resource = Resource.find_by(key: 'deal_desk')
    all_scope = Scope.find_by!(key: 'all')
    return unless resource

    Action.where(key: action_keys).each do |action|
      RolePermission.find_or_create_by!(role: role, resource: resource, action: action, scope: all_scope, granted: true)
    end
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

    # Deal Desk: managers get the full set including configure + transfer_unit.
    grant_deal_desk!(role, %w[read write quote configure transfer_unit])

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
    # Read-only users get 'all' scope for read access (company-wide visibility)
    # This is intentional - read-only means they can VIEW everything but not modify
    all_scope = Scope.find_by!(key: 'all')
    read_action = Action.find_by!(key: 'read')

    Resource.active.each do |resource|
      RolePermission.find_or_create_by!(
        role: role,
        resource: resource,
        action: read_action,
        scope: all_scope,
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

    # Deal Desk: location managers also get configure + transfer_unit (the manager capability).
    grant_deal_desk!(role, %w[read write quote configure transfer_unit])

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
  
  def self.grant_service_tech_permissions!(role)
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')
    
    # Service techs get full access to service tickets
    service_resource = Resource.find_by(key: 'service')
    all_actions = Action.all
    
    if service_resource
      all_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: service_resource,
          action: action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
    end
    
    # Read access to inventory and contacts
    read_action = Action.find_by(key: 'read')
    %w[inventory crm contacts].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      if resource && read_action
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: read_action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
    end
  end
  
  def self.grant_sales_rep_permissions!(role)
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')
    operational_actions = Action.where(key: %w[create read update delete export])

    # Deal Desk: reps build/quote/compare freely (no configure, no transfer_unit).
    grant_deal_desk!(role, %w[read write quote])
    
    # Full access to sales resources
    %w[quotes deals sales crm contacts leads].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource
      
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
    
    # Read access to inventory and finance
    read_action = Action.find_by(key: 'read')
    %w[inventory payments invoices].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      if resource && read_action
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: read_action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
    end
  end
  
  def self.grant_finance_staff_permissions!(role)
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')
    operational_actions = Action.where(key: %w[create read update delete export])
    
    # Full access to finance resources
    %w[payments invoices finance].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource
      
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
    
    # Read access to contacts, deals, and quotes
    read_action = Action.find_by(key: 'read')
    %w[contacts deals quotes crm].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      if resource && read_action
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: read_action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
    end
  end
  
  def self.grant_crm_specialist_permissions!(role)
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')
    operational_actions = Action.where(key: %w[create read update delete export])
    
    # Full access to CRM resources
    %w[crm contacts leads accounts].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource
      
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
    
    # Read access to quotes and deals
    read_action = Action.find_by(key: 'read')
    %w[quotes deals sales].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      if resource && read_action
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: read_action,
          scope: assigned_locations_scope,
          granted: true
        )
      end
    end
  end
  
  def self.grant_inventory_manager_permissions!(role)
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')
    operational_actions = Action.where(key: %w[create read update delete export])
    
    # Full access to inventory and operations
    %w[inventory operations vehicles].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource
      
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
    
    # Read access to service and contacts
    read_action = Action.find_by(key: 'read')
    %w[service contacts crm].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      if resource && read_action
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: read_action,
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
