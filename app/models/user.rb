# frozen_string_literal: true

class User < ApplicationRecord
  has_secure_password
  
  # Associations
  belongs_to :company, optional: true
  has_many :activities, dependent: :nullify
  has_many :reminders, dependent: :destroy
  has_many :user_locations, dependent: :destroy
  has_many :user_tour_completions, dependent: :destroy
  has_many :locations, through: :user_locations
  has_many :login_activities, dependent: :destroy
  # Phones allowed to unlock with Face ID instead of a password.
  has_many :device_sessions, as: :owner, dependent: :destroy
  has_many :assigned_tasks, class_name: 'Task', foreign_key: 'assigned_to_id', dependent: :nullify

  # Commission Payment Associations
  has_many :commission_payments, foreign_key: 'payee_user_id', dependent: :nullify
  has_many :approved_payments, class_name: 'CommissionPayment', foreign_key: 'approved_by_user_id', dependent: :nullify
  has_many :paid_payments, class_name: 'CommissionPayment', foreign_key: 'paid_by_user_id', dependent: :nullify
  has_many :reversed_payments, class_name: 'CommissionPayment', foreign_key: 'reversed_by_user_id', dependent: :nullify

  # A password change has to reach the phones too. Biometric unlock bypasses
  # the password by design, so leaving those sessions alive would mean someone
  # who changed their password because they feared it was known still had a
  # device in the wild that never needs it. Hung off the model rather than the
  # reset service because passwords change from several places.
  after_update_commit :revoke_device_sessions_after_password_change,
                      if: :saved_change_to_password_digest?

  # RBAC System Associations
  has_many :user_role_assignments, dependent: :destroy
  has_many :roles, through: :user_role_assignments

  # Agreement & E-Sign Module
  has_many :prepared_agreements, class_name: 'Agreement', foreign_key: :prepared_by_id, dependent: :nullify

  # Notification System Associations
  has_many :notifications, as: :recipient, dependent: :destroy
  has_one :user_email_connection, dependent: :destroy
  has_many :notification_preferences, dependent: :destroy

  # Email Connection Associations (for sending from personal email)
  has_many :user_email_connections, dependent: :destroy

  validates :email, presence: true, uniqueness: true
  validates :first_name, presence: true, if: -> { name.blank? }
  validates :password, length: { minimum: 6 }, if: -> { password.present? }

  # Scopes
  scope :active,           -> { where(status: 'active') }
  scope :platform_admins,  -> { where(role: %w[platform_admin super_admin]) }
  
  # Virtual attribute for full name (backward compatibility with 'name' field)
  def name
    if first_name.present? && last_name.present?
      "#{first_name} #{last_name}"
    else
      read_attribute(:name) || first_name || last_name || email
    end
  end
  
  # Alias for consistency with other models
  def full_name
    name
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

  # Record sign-in activity for "Last Login" reporting. Token refresh keeps a
  # session alive without a fresh login, so active users on long-lived sessions
  # would otherwise show as "never logged in". Throttled so we don't write on
  # every refresh; update_column skips validations/callbacks and updated_at.
  def touch_sign_in!(throttle: 10.minutes)
    return if last_sign_in_at.present? && last_sign_in_at > throttle.ago
    update_column(:last_sign_in_at, Time.current)
  rescue => e
    Rails.logger.warn("[touch_sign_in!] user #{id}: #{e.message}")
    nil
  end

  # Legacy Role helpers (kept for backward compatibility)
  def admin?
    role == 'admin' || role == 'super_admin' || role == 'platform_admin'
  end
  
  # RBAC-aware admin check - includes company_admin via RBAC
  def effective_admin?
    return true if admin?  # Legacy admin role
    return true if platform_admin?
    return true if super_admin?
    return true if company_admin?  # RBAC-based company admin
    false
  end
  
  def tenant?
    role == 'tenant'
  end
  
  def super_admin?
    role == 'super_admin'
  end
  
  def platform_admin?
    role == 'platform_admin'
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
    has_permission?(resource_key, action_key, scope_key, company_id)
  end
  
  # Optimized RBAC permission check - avoids N+1 queries
  def has_permission?(resource, action, scope = 'all', company_id = nil)
    # Platform admins, super admins, and company admins have all permissions
    return true if platform_admin?
    return true if super_admin?
    return true if company_admin?

    # Get the company
    check_company = company_id ? Company.find_by(id: company_id) : self.company
    
    # If RBAC is disabled for the company, allow all access
    return true unless check_company&.use_rbac_system
    
    # Use cached permissions to avoid repeated queries
    cached_permissions = rbac_permissions_cache(check_company.id)
    
    # Check if any permission matches
    cached_permissions.any? do |perm|
      resource_match = perm[:resource] == resource || perm[:resource] == '*'
      action_match = perm[:action] == action || perm[:action] == '*'
      scope_match = perm[:scope] == scope || perm[:scope] == 'all'
      
      if resource_match && action_match && scope_match
        Rails.logger.info "[RBAC] Permission granted: User #{id} has #{resource}:#{action}:#{scope} via role #{perm[:role_name]}"
        true
      else
        false
      end
    end
  end
  
  # Cache permissions for this request to avoid N+1 queries
  # Returns array of hashes: [{resource: 'x', action: 'y', scope: 'z', role_name: 'Role'}]
  def rbac_permissions_cache(company_id)
    @rbac_permissions_cache ||= {}
    return @rbac_permissions_cache[company_id] if @rbac_permissions_cache.key?(company_id)
    
    # DEBUG: Log all role assignments for this user to diagnose permission issues
    all_assignments = user_role_assignments.includes(:role)
    Rails.logger.info "🔍 [RBAC DEBUG] User #{id} (#{email}) has #{all_assignments.count} total role assignments"
    all_assignments.each do |a|
      Rails.logger.info "  - Assignment ID: #{a.id}, Role: #{a.role&.name} (#{a.role&.key}), company_id: #{a.company_id.inspect}, tier: #{a.tier}, expires_at: #{a.expires_at.inspect}"
    end
    
    # Single optimized query with all eager loading
    # BUG FIX: Also include assignments where company_id matches OR company_id is NULL (legacy)
    role_assignments = user_role_assignments
                       .joins(:role)
                       .includes(role: { role_permissions: [:resource, :action, :scope] })
                       .where('user_role_assignments.company_id = ? OR user_role_assignments.company_id IS NULL', company_id)
                       .active
    
    Rails.logger.info "🔍 [RBAC DEBUG] Found #{role_assignments.count} active role assignments for company #{company_id}"
    
    permissions = []
    
    role_assignments.each do |assignment|
      role = assignment.role
      next unless role&.active
      
      Rails.logger.info "🔍 [RBAC DEBUG] Processing role: #{role.name} (#{role.key}) with #{role.role_permissions.count} permissions"
      
      # Use .select on loaded association to avoid new queries
      role.role_permissions.select(&:granted).each do |permission|
        permissions << {
          resource: permission.resource.key,
          action: permission.action.key,
          scope: permission.scope.key,
          role_name: role.name
        }
      end
    end
    
    Rails.logger.info "🔍 [RBAC DEBUG] Final permission count: #{permissions.count}"
    
    @rbac_permissions_cache[company_id] = permissions
  end

  # Check if user has a specific role
  def has_role?(role_key, tier = nil)
    query = roles.where(key: role_key)
    query = query.where(tier: tier) if tier
    query.exists?
  end

  # Check if user is a company admin (role column OR RBAC)
  def company_admin?
    return true if platform_admin?  # Platform admins have full access
    return true if role == 'company_admin'  # Check role column directly (works with RBAC off)
    return false unless uses_rbac?
    roles.exists?(key: 'company_admin', tier: 'company')
  end

  # Get all locations accessible to this user
  def accessible_locations
    return company.locations if platform_admin? || admin? || company_admin?
    
    # Company-tier roles get access to ALL company locations
    has_company_tier_role = user_role_assignments
      .where(tier: 'company')
      .where(company_id: company_id)
      .active
      .exists?
    
    if has_company_tier_role
      return company.locations
    end
    
    # Location-tier roles only get their assigned locations
    direct_location_ids = user_role_assignments
      .where(tier: 'location')
      .pluck(:location_id)
    
    Location.where(id: direct_location_ids.uniq)
  end

  # Get all regions accessible to this user
  def accessible_regions
    return [] unless platform_admin? || admin? || company_admin?
    
    # Regions not implemented yet - return empty array
    []
  end

  # Get all permissions for a user in a company (optimized)
  #
  # This list drives what the frontend *shows* (sidebar items, tabs, buttons).
  # It is not the authorization gate: that stays in #has_permission? and
  # PermissionService, which are deliberately more permissive for admins.
  #
  # Company admins used to short-circuit to '*:*:*' here, and the frontend
  # reads any wildcard as "skip the permission matrix entirely". That made a
  # narrowed menu impossible to express for anyone holding company_admin, so
  # the matrix looked like it silently did nothing. Expand the real grants
  # instead. The company_admin role covers all 60 resources, so a normal admin
  # still sees the full menu; the difference is that turning something off now
  # takes effect.
  def permissions_for_company(company_id)
    return ['*:*:*'] if platform_admin? # Platform admins have all permissions
    return ['*:*:*'] if super_admin? # All permissions

    check_company = Company.find_by(id: company_id)
    return ['*:*:*'] unless check_company&.use_rbac_system # All permissions if RBAC disabled

    # Use the same cache as has_permission? for consistency
    cached_permissions = rbac_permissions_cache(company_id)

    # A legacy admin carries role == 'company_admin' on the column with no RBAC
    # assignment behind it, so there is nothing to expand. Falling through would
    # hand the frontend an empty list and blank their navigation.
    return ['*:*:*'] if cached_permissions.empty? && company_admin?

    cached_permissions.map do |perm|
      "#{perm[:resource]}:#{perm[:action]}:#{perm[:scope]}"
    end.uniq
  end
  
  # Get user's roles for a company
  def roles_for_company(company_id)
    user_role_assignments
      .includes(:role)
      .where(company_id: company_id)
      .active
      .map(&:role)
      .compact
      .select(&:active)
  end

  # True if the user has any active role assignment at company tier for this
  # company. Distinct from the role's *intrinsic* tier — a role defined as
  # tier='location' can still be assigned at tier='company' on the assignment
  # row, which grants access to all locations. Used by build_location_data in
  # the auth controllers (login/impersonation/MFA/invitation accept).
  def has_company_tier_role_for?(company_id)
    user_role_assignments
      .where(company_id: company_id, tier: 'company')
      .active
      .exists?
  end

  # Assign an RBAC role to this user
  # @param role_identifier [String, Integer] - Role key, name, or ID
  # @param company_id [Integer] - Company to assign role for (defaults to user's company)
  # @param tier [String] - 'company', 'region', or 'location' (defaults to role's tier or 'company')
  # @param assigned_by [User] - User who assigned this role (optional)
  # @param location_id [Integer] - Location ID for location-tier roles (optional)
  # @param region_id [Integer] - Region ID for region-tier roles (optional)
  # @return [UserRoleAssignment, nil] - The created/existing assignment or nil if role not found
  def assign_rbac_role(role_identifier, company_id: nil, tier: nil, assigned_by: nil, location_id: nil, region_id: nil)
    target_company_id = company_id || self.company_id
    return nil unless target_company_id

    # Find the role by key, name, or ID
    role = find_role_by_identifier(role_identifier)
    return nil unless role

    # Determine tier from role if not specified
    effective_tier = tier || role.tier || 'company'

    # DB CHECK CONSTRAINT: tier='location' requires location_id IS NOT NULL
    # If assigning a location-tier role without a specific location, promote to 'company' tier
    # so the user gets the permissions company-wide (common for Sales Rep, Service Tech, etc.)
    if effective_tier == 'location' && location_id.blank?
      effective_tier = 'company'
    end

    # Check if assignment already exists
    existing = user_role_assignments.find_by(
      role_id: role.id,
      company_id: target_company_id,
      tier: effective_tier,
      location_id: location_id,
      region_id: region_id
    )
    return existing if existing

    # Create new assignment
    assignment = user_role_assignments.create!(
      role_id: role.id,
      company_id: target_company_id,
      tier: effective_tier,
      assigned_by: assigned_by,
      location_id: location_id,
      region_id: region_id,
      assigned_at: Time.current
    )

    Rails.logger.info "✅ [RBAC] Assigned role '#{role.name}' (#{role.key}) to user #{id} (#{email}) for company #{target_company_id}"
    assignment
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "❌ [RBAC] Failed to assign role: #{e.message}"
    nil
  end

  # Remove all RBAC roles for a company and assign a new one
  # Use this when changing a user's role (e.g., from Staff to Admin)
  def replace_rbac_role(role_identifier, company_id: nil, tier: 'company', assigned_by: nil)
    target_company_id = company_id || self.company_id
    return nil unless target_company_id

    role = find_role_by_identifier(role_identifier)
    return nil unless role

    ActiveRecord::Base.transaction do
      # Remove ALL existing role assignments for this company (regardless of tier)
      # This ensures clean replacement when switching between company and location-tier roles
      removed = user_role_assignments.where(company_id: target_company_id).where(location_id: nil).destroy_all
      Rails.logger.info "🔄 [RBAC] Removed #{removed.count} existing role(s) for user #{id} in company #{target_company_id}"

      # Assign the new role (assign_rbac_role handles tier promotion for location roles without location_id)
      assign_rbac_role(role_identifier, company_id: target_company_id, assigned_by: assigned_by)
    end
  end

  # ==================== EMAIL CONNECTION METHODS ====================
  
  # Get the default email connection for this user
  def default_email_connection
    user_email_connections.active.verified.find_by(is_default: true) ||
      user_email_connections.active.verified.first
  end
  
  # Check if user has a verified email connection
  def has_email_connection?
    user_email_connections.active.verified.exists?
  end
  
  # Get the email address to use for sending (falls back to user's email)
  def sending_email_address
    default_email_connection&.email_address || email
  end
  
  # Get the BCC address for capturing external emails
  def bcc_capture_address
    ReplyToAddressService.generate_bcc_address(self)
  end

  private

  def revoke_device_sessions_after_password_change
    DeviceSession.revoke_all_for(self, 'password_changed')
  rescue StandardError => e
    Rails.logger.error("[DeviceSession] Could not revoke after password change for user #{id}: #{e.message}")
  end

  # Find a role by various identifiers
  def find_role_by_identifier(identifier)
    return nil if identifier.blank?

    # If it's an integer or looks like an ID, find by ID first
    if identifier.is_a?(Integer) || identifier.to_s.match?(/\A\d+\z/)
      role = Role.find_by(id: identifier)
      return role if role
    end

    identifier_str = identifier.to_s

    # Map common legacy role names to RBAC role keys
    role_key_mapping = {
      'Company Administrator' => 'company_admin',
      'company_administrator' => 'company_admin',
      'admin' => 'company_admin',
      'Company Manager' => 'company_manager',
      'manager' => 'company_manager',
      'Company Staff' => 'company_staff',
      'staff' => 'company_staff',
      'Read-Only User' => 'company_read_only',
      'read_only' => 'company_read_only',
      'readonly' => 'company_read_only',
      'Location Administrator' => 'location_admin',
      'location_administrator' => 'location_admin',
      'Location Manager' => 'location_manager',
      'Location Staff' => 'location_staff',
      'Service Technician' => 'service_tech',
      'service_technician' => 'service_tech',
      'Sales Representative' => 'sales_rep',
      'sales_representative' => 'sales_rep',
      'sales_rep' => 'sales_rep',
      'Finance Staff' => 'finance_staff',
      'finance_staff' => 'finance_staff',
      'CRM Specialist' => 'crm_specialist',
      'crm_specialist' => 'crm_specialist',
      'Inventory Manager' => 'inventory_manager',
      'inventory_manager' => 'inventory_manager'
    }

    # Try mapped key first
    mapped_key = role_key_mapping[identifier_str]
    if mapped_key
      role = Role.find_by(key: mapped_key)
      return role if role
    end

    # Try by exact key
    role = Role.find_by(key: identifier_str)
    return role if role

    # Try by exact name
    role = Role.find_by(name: identifier_str)
    return role if role

    # Try case-insensitive key match
    role = Role.where('LOWER(key) = ?', identifier_str.downcase).first
    return role if role

    # Try case-insensitive name match
    role = Role.where('LOWER(name) = ?', identifier_str.downcase).first
    return role if role

    Rails.logger.warn "⚠️ [RBAC] Could not find role for identifier: #{identifier_str}"
    nil
  end
  
  # Check if user has access to a company
  def has_access_to_company?(company_id)
    return true if super_admin?
    company_id.to_i == self.company_id || user_role_assignments.where(company_id: company_id).exists?
  end
end
