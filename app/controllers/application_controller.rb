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
    Current.company_id = current_company_id
    Current.location_id = current_location_id
    
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
    # For platform_admin/tenant/super_admin users, allow override via X-Company-ID header (platform admin switching)
    if current_user&.role.in?(['platform_admin', 'tenant', 'super_admin', 'admin'])
      # Try both X-Company-ID and X-Company-Context for backward compatibility
      context_company_id = request.headers['X-Company-ID']&.to_i || request.headers['X-Company-Context']&.to_i
      
      if context_company_id.present? && context_company_id > 0
        Rails.logger.info "[ApplicationController] Platform admin #{current_user.email} switching to company #{context_company_id}"
        # Verify the platform admin has access to this company
        # For now, platform admins can access any company
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
    unless current_portal_buyer
      render json: { error: 'Unauthorized' }, status: :unauthorized
      return
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
    if current_user.admin?
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
    return true if current_user.admin?
    
    # Check if user has an active assignment to this location
    current_user_locations.exists?(id: location.id)
  end
  
  def location_admin?(location)
    return false unless current_user && location
    
    # Company admins have admin rights everywhere
    return true if current_user.admin?
    
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
    return true if current_user.admin?
    
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
      if current_user&.platform_admin? || current_user&.super_admin? || current_user&.admin?
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
        # Location-tier users can only access their assigned locations
        user_location = UserLocation.find_by(
          user_id: current_user&.id,
          location_id: header_location_id,
          active: true
        )
        
        if user_location
          @current_location_id = header_location_id
          Rails.logger.info "[Location] User #{current_user.email} filtering by assigned location: #{header_location_id}"
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
      current_user.admin? ? current_company.regions.pluck(:id) : []
    end
  end
  
  private
  
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
    unless current_user&.platform_admin? || current_user&.super_admin?
      Rails.logger.warn(
        "[Authorization] User #{current_user&.id} denied platform admin access"
      )
      render json: { 
        error: 'Forbidden - Platform admin access required'
      }, status: :forbidden
      return false
    end
    true
  end

end
