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

  # Fills in any resource/action pair the role is missing.
  #
  # `granted` is deliberately not part of the lookup. It used to be, which meant
  # that once anyone revoked a permission (granted: false), this tried to INSERT
  # a second row for the same role/resource/action/scope and hit the unique
  # index. Narrowing a company_admin by revoking permissions is now the intended
  # way to shape a persona, so that path has to survive a re-seed. An explicit
  # revoke is a decision: fill gaps, never overwrite.
  def self.grant_full_permissions!(role)
    all_scope = Scope.find_by!(key: 'all')

    Resource.active.each do |resource|
      Action.all.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: all_scope
        ) { |rp| rp.granted = true }
      end
    end
  end

  # Bring an existing database in line with resources added after its first seed.
  #
  # seed_defaults bails out with `return if system_roles.any?`, so a resource
  # added later is born ungranted and stays that way: it shows up in the
  # permission matrix, no role holds it, and every RBAC non-admin is denied on
  # it forever. Admins never noticed because they short-circuit in
  # has_permission? before the matrix is consulted. Safe to re-run.
  def self.reconcile_system_permissions!
    admin = system_roles.find_by(key: 'company_admin')
    grant_full_permissions!(admin) if admin

    # Notifications are personal rather than privileged: every role sees its own.
    notifications = Resource.find_by(key: 'notifications')
    read = Action.find_by(key: 'read')
    all_scope = Scope.find_by(key: 'all')
    return unless notifications && read && all_scope

    system_roles.each do |role|
      RolePermission.find_or_create_by!(
        role: role,
        resource: notifications,
        action: read,
        scope: all_scope
      ) { |rp| rp.granted = true }
    end

    revoke_admin_resources_from_non_admin_roles!
  end

  # Resources that belong to whoever runs the dealership, not to whoever works
  # in it. Every shipped non-admin template granted these, which is why a sales
  # rep still saw an Administration section, a Locations page and the user list.
  ADMIN_TIER_RESOURCES = %w[
    company_settings users locations branding activity_logs data_import_export
    integrations settings
  ].freeze

  # Roles that legitimately keep them.
  ADMIN_ROLE_KEYS = %w[company_admin location_admin].freeze

  # Revoke rather than delete: a false row is a visible, deliberate "off" in the
  # permission matrix, and it survives reconcile_system_permissions! (which only
  # fills gaps). Deleting would leave a hole that the next top-up refills.
  def self.revoke_admin_resources_from_non_admin_roles!
    resource_ids = Resource.where(key: ADMIN_TIER_RESOURCES).pluck(:id)
    return if resource_ids.empty?

    RolePermission
      .where(role: system_roles.where.not(key: ADMIN_ROLE_KEYS), resource_id: resource_ids, granted: true)
      .update_all(granted: false)
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
    all_scope = Scope.find_by!(key: 'all')
    operational_actions = Action.where(key: %w[create read update delete export])
    read_action = Action.find_by!(key: 'read')

    # Full CRUD (company-wide) on service tickets + the field-ops resources a tech actually
    # touches: parts (pull/consume), vendors, warranty claims, tasks, documents, calendar.
    %w[
      service parts vendors warranty_claims
      tasks documents calendar
    ].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource

      operational_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: all_scope,
          granted: true
        )
      end
    end

    # Read-only (company-wide): inventory + CRM/contacts context for the job.
    %w[inventory crm contacts manufacturers].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource && read_action

      RolePermission.find_or_create_by!(
        role: role,
        resource: resource,
        action: read_action,
        scope: all_scope,
        granted: true
      )
    end
  end
  
  def self.grant_sales_rep_permissions!(role)
    all_scope = Scope.find_by!(key: 'all')
    operational_actions = Action.where(key: %w[create read update delete export])
    read_action = Action.find_by!(key: 'read')

    # Deal Desk: reps get the FULL action set (read/write/quote/configure/transfer_unit/swap_unit),
    # company-wide. Per product decision, reps own Deal Desk end-to-end (no manager gate here).
    grant_deal_desk!(role, %w[read write quote configure transfer_unit swap_unit])

    # Full read+write on the core sales set, company-wide ('all' scope). Deals specifically get
    # full CRUD+export at 'all' per product decision (reps see/work all deals, not just their
    # location's). The linked sales objects use 'all' too so reps aren't blocked navigating
    # from a deal to its account/contact/quote.
    %w[quotes deals sales crm contacts leads accounts].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource

      operational_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: all_scope,
          granted: true
        )
      end
    end

    # Full CRUD on day-to-day rep workflow resources (company-wide). These were missing from the
    # original seed, which is why reps couldn't reach features added since.
    %w[tasks documents communications calendar agreements configurator].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource

      operational_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: all_scope,
          granted: true
        )
      end
    end

    # Read-only access (company-wide): reps can SEE these but not modify. Includes cost/margin
    # visibility on inventory + deals (read-only — they see margin but can't edit cost details),
    # plus product catalog, listings, finance docs, and reporting/dashboards.
    %w[
      inventory inventory_cost_details deals_cost_details products listings
      payments invoices loans reports dashboard
    ].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource && read_action

      RolePermission.find_or_create_by!(
        role: role,
        resource: resource,
        action: read_action,
        scope: all_scope,
        granted: true
      )
    end
  end
  
  def self.grant_finance_staff_permissions!(role)
    all_scope = Scope.find_by!(key: 'all')
    operational_actions = Action.where(key: %w[create read update delete export])
    read_action = Action.find_by!(key: 'read')

    # Deal Desk: finance gets read/write (they work the financial side of a desk — lender
    # programs, reserve, F&I — but configure/transfer/swap stay manager/sales-owned).
    grant_deal_desk!(role, %w[read write quote])

    # Full CRUD (company-wide) on finance + the ENTIRE Accounting module. This was the big gap:
    # finance staff previously had zero access to Accounting even though it's their core job.
    %w[
      finance payments invoices loans
      accounting chart_of_accounts journal_entries bank_accounts_accounting
      bank_reconciliation bills financial_reports budgets
      commissions commission_plans commission_components commission_payments
    ].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource

      operational_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: all_scope,
          granted: true
        )
      end
    end

    # Read-only (company-wide): finance needs to SEE the sales/CRM side + cost details +
    # reporting/dashboards, but not edit them.
    %w[
      crm contacts accounts deals quotes
      inventory inventory_cost_details deals_cost_details
      reports dashboard dashboard_finance dashboard_company_wide
      documents tasks
    ].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource && read_action

      RolePermission.find_or_create_by!(
        role: role,
        resource: resource,
        action: read_action,
        scope: all_scope,
        granted: true
      )
    end
  end
  
  def self.grant_crm_specialist_permissions!(role)
    all_scope = Scope.find_by!(key: 'all')
    operational_actions = Action.where(key: %w[create read update delete export])
    read_action = Action.find_by!(key: 'read')

    # Full CRUD (company-wide) on CRM + the rep/marketing workflow resources that were missing.
    %w[
      crm contacts leads accounts
      tasks documents communications calendar campaigns
    ].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource

      operational_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: all_scope,
          granted: true
        )
      end
    end

    # Read-only (company-wide): sales pipeline + reporting/dashboards.
    %w[quotes deals sales reports dashboard].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource && read_action

      RolePermission.find_or_create_by!(
        role: role,
        resource: resource,
        action: read_action,
        scope: all_scope,
        granted: true
      )
    end
  end
  
  def self.grant_inventory_manager_permissions!(role)
    all_scope = Scope.find_by!(key: 'all')
    operational_actions = Action.where(key: %w[create read update delete export])
    read_action = Action.find_by!(key: 'read')

    # Full CRUD (company-wide) on inventory + the entire Parts/Warehouse module + configurator,
    # listings, products, vendors. NOTE: the old seed granted 'operations' and 'vehicles', which
    # are NOT real resource keys (they silently no-op'd) — replaced with the actual keys.
    %w[
      inventory listings products configurator
      parts bins suppliers part_categories purchase_orders vendors
    ].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource

      operational_actions.each do |action|
        RolePermission.find_or_create_by!(
          role: role,
          resource: resource,
          action: action,
          scope: all_scope,
          granted: true
        )
      end
    end

    # Read-only (company-wide): cost visibility on inventory, service/CRM context, reporting,
    # and tasks.
    %w[
      inventory_cost_details service contacts crm
      reports dashboard tasks documents
    ].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      next unless resource && read_action

      RolePermission.find_or_create_by!(
        role: role,
        resource: resource,
        action: read_action,
        scope: all_scope,
        granted: true
      )
    end
  end

  def invalidate_permission_cache
    # Clear permission cache for all users with this role
    users.each do |user|
      Rails.cache.delete_matched("permissions:#{user.id}:*")
    end
  end
end
