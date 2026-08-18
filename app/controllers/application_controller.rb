# frozen_string_literal: true
require "ostruct"

class ApplicationController < ActionController::API
  include ActionController::Cookies
  include NotificationTriggers  # Add notification helper methods
  include CustomAuthorization   # Add custom financial permissions
  
  before_action :authenticate
  before_action :set_current_attributes

  private
  
  # Set Current attributes for use throughout the request
  # This allows models to access current context without explicit passing
  def set_current_attributes
    Current.user = current_user
    Current.original_user = original_user
    Current.company_id = current_company_id
    Current.location_id = current_location_id
    Current.ip_address = request.remote_ip

    if Rails.env.development? && Current.location_id.present?
      Rails.logger.info "📍 [Current] Location context set: #{Current.location_id}"
    end
  rescue => e
    Rails.logger.warn "[Current] Failed to set attributes: #{e.message}"
  end

  # Standard tenant isolation - sets @company from current user
  # Use as: before_action :set_company_scope
  def set_company_scope
    unless current_user
      Rails.logger.error "🚫 [set_company_scope] No authenticated user found"
      render json: { error: 'Authentication required' }, status: :unauthorized
      return false
    end
    
    company_id = current_company_id
    
    unless company_id.present?
      Rails.logger.error "🚫 [set_company_scope] User #{current_user.id} has no company_id"
      render json: { error: 'No company assigned to user' }, status: :forbidden
      return false
    end
    
    @company = ::Company.find_by(id: company_id)
    
    if @company.nil?
      Rails.logger.error "🚫 [set_company_scope] Company #{company_id} not found for user #{current_user.id}"
      render json: { error: 'Company not found' }, status: :not_found
      return false
    end
    
    Rails.logger.info "✅ [set_company_scope] Company scope set: #{@company.name} (ID: #{@company.id}) for user: #{current_user.email}"
    true
  end

  # Alias for compatibility
  def authenticate_user!
    authenticate
  end

  def authenticate
    # Extract token from Authorization header
    header = request.headers['Authorization']

    if header.present?
      token = header.split(' ').last
      decoded = JsonWebToken.decode(token)

      if decoded
        # Valid JWT token found
        @current_user_id = decoded[:user_id]
        @current_company_id = decoded[:company_id] || request.headers['X-Company-Id']&.to_i

        # Check for impersonation header (platform admins only)
        resolve_impersonation

        return
      else
        # Token decode failed (expired or invalid)
        Rails.logger.warn "[ApplicationController] JWT decode failed for token"
        render json: { error: 'Unauthorized - Invalid or expired token' }, status: :unauthorized
        return
      end
    end

    # No valid token - return unauthorized
    Rails.logger.warn "[ApplicationController] No authorization header present"
    render json: { error: 'Unauthorized - Missing authorization header' }, status: :unauthorized
  end

  def current_company_id
    # When impersonating, default to the impersonated user's company
    if impersonating?
      # Still allow X-Company-ID override for multi-company users
      context_company_id = request.headers['X-Company-ID']&.to_i || request.headers['X-Company-Context']&.to_i
      if context_company_id.present? && context_company_id > 0
        return context_company_id
      end
      return @impersonated_user.company_id
    end

    # Only platform admins and super admins can override company scope via header.
    # Previously this also allowed 'admin' and 'tenant' roles, which was a tenant-isolation hole —
    # a company-tier admin could set X-Company-ID to another tenant and read their data.
    if current_user&.platform_admin? || current_user&.super_admin?
      context_company_id = request.headers['X-Company-ID']&.to_i || request.headers['X-Company-Context']&.to_i

      if context_company_id.present? && context_company_id > 0
        Rails.logger.info "[ApplicationController] Platform admin #{current_user.email} switching to company #{context_company_id}"
        return context_company_id
      end
    end

    # Otherwise use the company from JWT token or user's company
    company_id = @current_company_id || current_user&.company_id
    Rails.logger.info "[ApplicationController] Using company_id #{company_id} for user #{current_user&.email}"
    company_id
  end

  def current_user
    return @current_user if defined?(@current_user)

    # When impersonating, current_user returns the impersonated user
    if @impersonated_user
      @current_user = @impersonated_user
      return @current_user
    end

    # Load user from JWT token
    if @current_user_id
      @current_user = User.find_by(id: @current_user_id)

      unless @current_user
        Rails.logger.error("JWT token contains invalid user_id: #{@current_user_id}")
        render json: { error: 'Unauthorized - User not found' }, status: :unauthorized
        return nil
      end

      return @current_user
    end

    # No authenticated user
    nil
  end

  # Returns the real authenticated user (platform admin) during impersonation,
  # or current_user when not impersonating. Use this for security checks.
  def original_user
    @original_user || current_user
  end

  # Whether the current request is an impersonation
  def impersonating?
    @impersonated_user.present?
  end
  
  # Portal authentication helpers
  def current_portal_buyer
    return @current_portal_buyer if @current_portal_buyer
    
    header = request.headers['Authorization']
    return nil unless header.present?
    
    token = header.split(' ').last
    decoded = JsonWebToken.decode(token)
    return nil unless decoded
    
    # Support both unified auth (user_id) and portal auth (buyer_portal_access_id)
    if decoded[:buyer_portal_access_id]
      # Old portal auth token
      @current_portal_buyer = BuyerPortalAccess.find_by(id: decoded[:buyer_portal_access_id])
    elsif decoded[:user_id] && decoded[:email]
      # Unified auth token - find BuyerPortalAccess by email
      @current_portal_buyer = BuyerPortalAccess.find_by(email: decoded[:email])
    end
    
    @current_portal_buyer
  rescue
    nil
  end

  def authenticate_portal_buyer!
    return if current_portal_buyer

    render json: portal_auth_error, status: :unauthorized
  end

  # Why the portal request could not be authenticated, in a form the client can
  # branch on. A bare 'Unauthorized' gave the portal nothing to work with, so an
  # expired proxy token (they last an hour) surfaced as an error toast on every
  # request instead of a prompt to re-authenticate.
  def portal_auth_error
    header = request.headers['Authorization']
    return { error: 'Missing authorization header', code: 'token_missing' } if header.blank?

    case JsonWebToken.token_state(header.split(' ').last)
    when :expired
      { error: 'Your portal session has expired. Please sign in again.', code: 'token_expired' }
    when :invalid
      { error: 'Invalid token', code: 'token_invalid' }
    else
      # Token is well-formed but names no reachable portal account.
      { error: 'Portal access not found', code: 'portal_access_not_found' }
    end
  end

  def authorize_buyer_resource!(resource)
    unless current_portal_buyer.buyer == resource.buyer
      render json: { error: 'Forbidden' }, status: :forbidden
      return
    end
  end

  # Location-based authorization helpers
  def current_user_locations
    return [] unless current_user
    return @current_user_locations if defined?(@current_user_locations)
    
    # Company admins have access to all locations
    if current_user.effective_admin?
      @current_user_locations = current_company.locations.where(is_deleted: false, active: true)
    else
      # Regular users only access their assigned locations
      @current_user_locations = current_user.locations
                                           .where(is_deleted: false, active: true)
                                           .where(user_locations: { active: true })
    end
    
    @current_user_locations
  end
  
  def can_access_location?(location)
    return false unless current_user && location
    
    # Company admins can access all locations
    return true if current_user.effective_admin?
    
    # Check if user has an active assignment to this location
    current_user_locations.exists?(id: location.id)
  end
  
  def location_admin?(location)
    return false unless current_user && location
    
    # Company admins have admin rights everywhere
    return true if current_user.effective_admin?
    
    # Check if user is a location admin for this specific location
    UserLocation.exists?(
      user_id: current_user.id,
      location_id: location.id,
      location_role: 'location_admin',
      active: true
    )
  end
  
  def can_manage_location?(location)
    return false unless current_user && location
    
    # Company admins can manage all locations
    return true if current_user.effective_admin?
    
    # Location admins and managers can manage operations
    user_location = UserLocation.find_by(
      user_id: current_user.id,
      location_id: location.id,
      active: true
    )
    
    user_location&.location_role&.in?(['location_admin', 'location_manager'])
  end
  
  def current_company
    return @current_company if defined?(@current_company)
    @current_company = ::Company.find_by(id: current_company_id)
  end
  
  # Get the active location ID from X-Location-ID header
  # Used for filtering data when user selects a specific location
  def current_location_id
    return @current_location_id if defined?(@current_location_id)
    
    header_location_id = request.headers['X-Location-ID']&.to_i
    
    if header_location_id.present? && header_location_id > 0
      # Verify user has access to this location
      if current_user&.platform_admin? || current_user&.super_admin? || current_user&.effective_admin?
        # Admins can access any location in their company
        location = Location.find_by(id: header_location_id, company_id: current_company_id)
        if location
          @current_location_id = header_location_id
          Rails.logger.info "[Location] Admin #{current_user.email} filtering by location: #{location.name} (#{header_location_id})"
        else
          Rails.logger.warn "[Location] Location #{header_location_id} not found or doesn't belong to company #{current_company_id}"
          @current_location_id = nil
        end
      else
        # Defer to User#accessible_locations rather than reading user_locations here.
        #
        # That method is the single source of truth for this question and already
        # says a company-tier role reaches every location in the company. The
        # UserLocation.find_by this replaces only knew about explicit per-location
        # rows, so a company-tier user -- Finance Staff, tier: company -- was told on
        # every single request that they had no access to a location their own user
        # settings grant them. Two authorities, disagreeing, and the wrong one wired
        # to the request.
        #
        # Note the consequence was not a lockout but the opposite: the branch below
        # sets @current_location_id to nil, which removes the location filter and
        # widens the response to the whole company. Meanwhile per-record lookups like
        # VehiclesController#set_vehicle scope by accessible_location_ids and kept
        # returning 404, which is how a home could be listed but not opened.
        if current_user && current_user.accessible_locations.exists?(id: header_location_id)
          @current_location_id = header_location_id
          Rails.logger.info "[Location] User #{current_user.email} filtering by accessible location: #{header_location_id}"
        else
          Rails.logger.warn "[Location] User #{current_user&.email} does not have access to location #{header_location_id}"
          @current_location_id = nil
        end
      end
    else
      @current_location_id = nil
    end
    
    @current_location_id
  end
  
  # Get the current location object
  def current_location
    return @current_location if defined?(@current_location)
    @current_location = current_location_id ? Location.find_by(id: current_location_id) : nil
  end
  
  # Helper to scope a query by location if a location is selected
  # Usage: scope_by_location(Inventory.all, :location_id)
  def scope_by_location(relation, location_column = :location_id)
    if current_location_id.present?
      relation.where(location_column => current_location_id)
    else
      relation
    end
  end
  
  # Check if we're filtering by a specific location
  def location_filtered?
    current_location_id.present?
  end

  # Convert a relative path to an absolute URL using the API host
  def absolute_url(path)
    return path if path.blank?
    return path if path.start_with?('http://', 'https://')

    base_url = if request.present?
      "#{request.protocol}#{request.host_with_port}"
    else
      ENV['RAILS_API_URL'] || 'https://localhost:3001'
    end

    "#{base_url}#{path}"
  end

  # RBAC Authorization Helpers
  
  # Dual authorization check - RBAC or legacy
  #
  # @param resource_key [String] Resource identifier
  # @param action_key [String] Action identifier
  # @param scope_key [String] Scope identifier (default: 'all')
  # @param context [Hash] Context for scope validation
  # @return [Boolean] true if authorized
  def can?(resource_key, action_key, scope_key = 'all', context = {})
    return false unless current_user
    
    # Platform admins, super admins always have full access
    return true if current_user.platform_admin?
    return true if current_user.super_admin?
    
    # Get the company context for RBAC checks
    company_id = current_company_id
    company = Company.find_by(id: company_id)
    
    # Check if the company uses RBAC
    if company && company.use_rbac_system
      # Check if user is a company admin (via RBAC) - they get full access
      if current_user.company_admin?
        Rails.logger.info "[RBAC] Company Admin full access for #{current_user.email}"
        return true
      end
      
      # Check RBAC permissions
      result = current_user.has_permission?(resource_key, action_key, scope_key, company_id)
      
      # Fallback: Check user_role_assignments for company_admin role (flexible match)
      if !result
        has_admin_role = current_user.user_role_assignments
          .joins(:role)
          .where(company_id: company_id)
          .where(roles: { tier: 'company' })
          .where("roles.key IN (?)", ['company_admin', 'admin', 'super_admin'])
          .exists?
        
        if has_admin_role
          Rails.logger.info "[RBAC] Company Admin role override for #{current_user.email}"
          return true
        end
      end
      
      result
    else
      # Company doesn't use RBAC, use legacy authorization
      # Legacy admin/tenant check
      return true if current_user.admin?
      return true if current_user.tenant?
      
      legacy_authorize(resource_key, action_key)
    end
  end
  
  # Authorize action or raise error
  #
  # @param resource_key [String] Resource identifier
  # @param action_key [String] Action identifier
  # @param scope_key [String] Scope identifier (default: 'all')
  # @param context [Hash] Context for scope validation
  # @return [Boolean] true if authorized, renders error and returns false if not
  def authorize_action!(resource_key, action_key, scope_key = 'all', context = {})
    Rails.logger.info "🔐 [authorize_action!] Checking: #{resource_key}:#{action_key}:#{scope_key} for user #{current_user&.email}"
    
    result = can?(resource_key, action_key, scope_key, context)
    
    if result
      Rails.logger.info "✅ [authorize_action!] GRANTED: #{resource_key}:#{action_key}:#{scope_key}"
    else
      Rails.logger.warn "❌ [Authorization] DENIED for user #{current_user&.id}: #{resource_key}:#{action_key}:#{scope_key}"
      render json: { 
        error: 'Forbidden - Insufficient permissions',
        required_permission: "#{resource_key}:#{action_key}:#{scope_key}"
      }, status: :forbidden
    end
    
    result
  end
  
  # Check if current user can access a specific location (RBAC-aware)
  #
  # @param location_id [Integer] Location ID
  # @return [Boolean] true if user can access location
  def can_access_location_rbac?(location_id)
    return false unless current_user
    
    if current_user.uses_rbac?
      permission_service.can_access_location?(location_id)
    else
      # Legacy: check if location is in user's assigned locations
      location = Location.find_by(id: location_id)
      can_access_location?(location)
    end
  end
  
  # Check if current user can access a specific region (RBAC-aware)
  #
  # @param region_id [Integer] Region ID
  # @return [Boolean] true if user can access region
  def can_access_region_rbac?(region_id)
    return false unless current_user
    
    if current_user.uses_rbac?
      permission_service.can_access_region?(region_id)
    else
      # Legacy: company admins only
      current_user.admin?
    end
  end
  
  # Get permission service instance for current user
  #
  # @return [PermissionService] Permission service instance
  def permission_service
    @permission_service ||= PermissionService.new(current_user) if current_user
  end
  
  # Get all accessible locations for current user (RBAC-aware)
  #
  # @return [ActiveRecord::Relation] Locations accessible to user
  def accessible_locations
    return Location.none unless current_user
    
    if current_user.uses_rbac?
      Location.where(id: permission_service.accessible_location_ids)
    else
      current_user_locations
    end
  end
  
  # Get all accessible regions for current user (RBAC-aware)
  #
  # @return [Array<Integer>] Region IDs accessible to user
  def accessible_regions
    return [] unless current_user
    
    if current_user.uses_rbac?
      permission_service.accessible_region_ids
    else
      # Legacy: company admins get all regions
      current_user.effective_admin? ? current_company.regions.pluck(:id) : []
    end
  end
  
  private
  
  # Resolve impersonation from JWT claim or X-Impersonated-User-ID header.
  # JWT claim (impersonated_by) is set when the impersonation token is issued.
  # Header fallback allows the frontend to also pass the target user ID explicitly.
  # Sets @impersonated_user and @original_user when valid.
  def resolve_impersonation
    header = request.headers['Authorization']
    return unless header.present?

    token = header.split(' ').last
    decoded = JsonWebToken.decode(token)
    return unless decoded

    # Method 1: JWT-based impersonation (impersonated_by claim in token)
    if decoded[:impersonated_by].present?
      admin_user = User.find_by(id: decoded[:impersonated_by])
      return unless admin_user&.platform_admin? || admin_user&.super_admin?

      target = User.find_by(id: decoded[:user_id])
      return unless target

      @original_user = admin_user
      @impersonated_user = target
      Rails.logger.info "🎭 [Impersonation] #{admin_user.email} (ID: #{admin_user.id}) acting as #{target.email} (ID: #{target.id})"
      return
    end

    # Method 2: Header-based impersonation (X-Impersonated-User-ID)
    impersonated_id = request.headers['X-Impersonated-User-ID']&.to_i
    return unless impersonated_id.present? && impersonated_id > 0

    real_user = User.find_by(id: @current_user_id)
    return unless real_user
    return unless real_user.platform_admin? || real_user.super_admin?

    target = User.find_by(id: impersonated_id)
    unless target
      Rails.logger.warn "[Impersonation] Target user #{impersonated_id} not found"
      return
    end

    if target.inactive? || target.suspended?
      Rails.logger.warn "[Impersonation] Target user #{impersonated_id} is inactive/suspended"
      return
    end

    @original_user = real_user
    @impersonated_user = target
    Rails.logger.info "🎭 [Impersonation] #{real_user.email} (ID: #{real_user.id}) acting as #{target.email} (ID: #{target.id})"
  end

  # Legacy authorization fallback for non-RBAC companies
  #
  # @param resource_key [String] Resource identifier
  # @param action_key [String] Action identifier
  # @return [Boolean] true if authorized
  def legacy_authorize(resource_key, action_key)
    return true if current_user.platform_admin? || current_user.admin? || current_user.super_admin?
    
    # Basic legacy rules
    case action_key
    when 'read', 'export'
      true # Most users can read
    when 'create', 'update'
      current_user.staff? || current_user.admin?
    when 'delete', 'manage'
      current_user.admin?
    else
      false
    end
  end
  
  # Require platform admin role for sensitive operations
  #
  # @return [Boolean] true if authorized, renders error and returns false if not
  def require_platform_admin!
    # Use original_user so platform admin guards work during impersonation
    admin = original_user
    unless admin&.platform_admin? || admin&.super_admin?
      Rails.logger.warn(
        "[Authorization] User #{admin&.id} denied platform admin access"
      )
      render json: {
        error: 'Forbidden - Platform admin access required'
      }, status: :forbidden
      return false
    end
    true
  end

  # Get visible field keys from active page layout for a module
  # Used to validate only fields that are actually in the user's form
  #
  # @param module_name [String] Module name (e.g., 'leads', 'contacts', 'accounts')
  # @return [Array<String>] Array of visible field keys (snake_case)
  def visible_layout_fields(module_name)
    return [] unless @company.present?
    
    layout = @company.page_layouts.for_module(module_name).find_by(layout_type: 'detail')
    return [] unless layout&.layout_data.present?
    
    sections = layout.layout_data['sections'] || []
    visible_keys = []
    
    sections.each do |section|
      fields = section['fields'] || []
      fields.each do |field|
        # Only include fields that are explicitly marked as visible
        visible_keys << field['key'] if field['visible'] != false && field['key'].present?
      end
    end
    
    visible_keys
  rescue => e
    Rails.logger.warn "[visible_layout_fields] Error loading layout for #{module_name}: #{e.message}"
    [] # On error, return empty array (fail open - allow all fields)
  end

  # Validate required fields that are visible in active layout
  # Returns array of error messages for missing required fields
  #
  # @param module_name [String] Module name (e.g., 'leads', 'contacts')
  # @param record [ActiveRecord::Base] Record to validate
  # @return [Array<String>] Error messages for missing fields
  # If submitted_keys is provided (Array of strings), only required fields
  # that appear in that list are validated. Used by partial updates (e.g.
  # Kanban drag-drop sends only {status: 'x'}) so a stale missing field on
  # an existing record doesn't fail a one-field change. Nil = validate all
  # required fields (the previous behavior, still used by create).
  def validate_visible_required_fields(module_name, record, submitted_keys: nil)
    visible_keys = visible_layout_fields(module_name)
    errors = []

    # If no layout or no visible fields, skip validation (fail open)
    return errors if visible_keys.empty?

    # Get field definitions for this module
    field_definitions = get_standard_field_definitions(module_name)

    submitted_set = submitted_keys ? submitted_keys.map(&:to_s).to_set : nil

    field_definitions.each do |field_def|
      key = field_def[:key]

      # Only validate if: 1) field is required AND 2) field is visible in layout
      next unless field_def[:required] && visible_keys.include?(key)

      # Partial update: skip required fields the caller didn't touch.
      next if submitted_set && !submitted_set.include?(key.to_s)

      # Check if value is present in the record
      value = record.send(key) rescue nil

      if value.blank?
        label = field_def[:label] || key.titleize
        errors << "#{label} is required"
      end
    end

    errors
  end

  # Get standard field definitions for a module
  # @param module_name [String] Module name
  # @return [Array<Hash>] Field definitions
  def get_standard_field_definitions(module_name)
    case module_name
    when 'leads'
      [
        { key: 'first_name', label: 'First Name', required: true },
        { key: 'last_name', label: 'Last Name', required: true },
        { key: 'email', label: 'Email', required: true },
        { key: 'phone', label: 'Phone', required: true },
      ]
    when 'contacts'
      [
        { key: 'first_name', label: 'First Name', required: true },
        { key: 'last_name', label: 'Last Name', required: true },
        { key: 'email', label: 'Email', required: true },
      ]
    when 'accounts'
      [
        { key: 'name', label: 'Name', required: true },
      ]
    else
      []
    end
  end

end
