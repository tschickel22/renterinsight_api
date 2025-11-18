# frozen_string_literal: true

# PermissionService
#
# Core service for RBAC permission checking with caching and scope validation.
# Handles three-layer permission model: Resource + Action + Scope
#
# Usage:
#   service = PermissionService.new(user)
#   service.can?('inventory', 'create', 'all') # => true/false
#   service.can?('inventory', 'update', 'assigned_locations', location_id: 123)
#
# Scope Validation:
#   - 'all': User can perform action company-wide
#   - 'assigned_regions': User can perform action in their assigned regions
#   - 'assigned_locations': User can perform action at their assigned locations
#   - 'own': User can only perform action on resources they own

class PermissionService
  CACHE_EXPIRY = 1.hour
  
  attr_reader :user
  
  def initialize(user)
    @user = user
  end
  
  # Main permission check method
  # 
  # @param resource_key [String] Resource identifier (e.g., 'inventory', 'users')
  # @param action_key [String] Action identifier (e.g., 'create', 'read', 'update')
  # @param scope_key [String] Scope identifier (default: 'all')
  # @param context [Hash] Additional context for scope validation
  # @return [Boolean] true if user has permission, false otherwise
  def can?(resource_key, action_key, scope_key = 'all', context = {})
    return false unless user.uses_rbac?
    return false if user.inactive? || user.suspended?
    
    cache_key = permission_cache_key(resource_key, action_key, scope_key)
    
    has_permission = Rails.cache.fetch(cache_key, expires_in: CACHE_EXPIRY) do
      check_permission(resource_key, action_key, scope_key)
    end
    
    return false unless has_permission
    
    # If permission exists, validate scope constraints
    validate_scope(scope_key, context)
  end
  
  # Check if user has any of the specified permissions
  #
  # @param permissions [Array<Hash>] Array of permission hashes
  #   [{resource: 'inventory', action: 'read'}, {resource: 'inventory', action: 'create'}]
  # @return [Boolean] true if user has at least one permission
  def can_any?(*permissions)
    permissions.any? do |perm|
      can?(perm[:resource], perm[:action], perm[:scope] || 'all', perm[:context] || {})
    end
  end
  
  # Check if user has all specified permissions
  #
  # @param permissions [Array<Hash>] Array of permission hashes
  # @return [Boolean] true only if user has all permissions
  def can_all?(*permissions)
    permissions.all? do |perm|
      can?(perm[:resource], perm[:action], perm[:scope] || 'all', perm[:context] || {})
    end
  end
  
  # Get all granted permissions for user
  #
  # @return [Array<Hash>] Array of permission hashes
  def all_permissions
    cache_key = "permissions:#{user.id}:all"
    
    Rails.cache.fetch(cache_key, expires_in: CACHE_EXPIRY) do
      user.roles.active.flat_map do |role|
        role.role_permissions.granted.includes(:resource, :action, :scope).map(&:to_h)
      end.uniq
    end
  end
  
  # Get permissions grouped by resource
  #
  # @return [Hash] Permissions grouped by resource key
  def permissions_by_resource
    all_permissions.group_by { |perm| perm[:resource] }
  end
  
  # Check if user can access a specific location
  #
  # @param location_id [Integer] Location ID
  # @return [Boolean] true if user can access location
  def can_access_location?(location_id)
    return true if user.admin? || user.company_admin?
    
    accessible_location_ids.include?(location_id)
  end
  
  # Check if user can access a specific region
  #
  # @param region_id [Integer] Region ID
  # @return [Boolean] true if user can access region
  def can_access_region?(region_id)
    return true if user.admin? || user.company_admin?
    
    accessible_region_ids.include?(region_id)
  end
  
  # Get all location IDs accessible to user
  #
  # @return [Array<Integer>] Array of location IDs
  def accessible_location_ids
    cache_key = "permissions:#{user.id}:accessible_locations"
    
    Rails.cache.fetch(cache_key, expires_in: CACHE_EXPIRY) do
      user.accessible_locations.pluck(:id)
    end
  end
  
  # Get all region IDs accessible to user
  #
  # @return [Array<Integer>] Array of region IDs
  def accessible_region_ids
    cache_key = "permissions:#{user.id}:accessible_regions"
    
    Rails.cache.fetch(cache_key, expires_in: CACHE_EXPIRY) do
      user.accessible_regions
    end
  end
  
  # Clear all cached permissions for this user
  def clear_cache
    Rails.cache.delete_matched("permissions:#{user.id}:*")
  end
  
  # Invalidate specific permission cache
  #
  # @param resource_key [String] Resource identifier
  # @param action_key [String] Action identifier
  # @param scope_key [String] Scope identifier
  def invalidate_permission(resource_key, action_key, scope_key = 'all')
    cache_key = permission_cache_key(resource_key, action_key, scope_key)
    Rails.cache.delete(cache_key)
  end
  
  private
  
  # Core permission check logic (without scope validation)
  #
  # @param resource_key [String] Resource identifier
  # @param action_key [String] Action identifier
  # @param scope_key [String] Scope identifier
  # @return [Boolean] true if permission exists in role
  def check_permission(resource_key, action_key, scope_key)
    user.roles.active.any? do |role|
      role.has_permission?(resource_key, action_key, scope_key)
    end
  end
  
  # Validate scope constraints based on context
  #
  # @param scope_key [String] Scope identifier
  # @param context [Hash] Context with location_id, region_id, owner_id, etc.
  # @return [Boolean] true if scope constraints are satisfied
  def validate_scope(scope_key, context)
    case scope_key
    when 'all'
      true
    when 'assigned_regions'
      validate_region_scope(context)
    when 'assigned_locations'
      validate_location_scope(context)
    when 'own'
      validate_owner_scope(context)
    else
      false
    end
  end
  
  # Validate region scope
  #
  # @param context [Hash] Must include :region_id
  # @return [Boolean] true if user can access region
  def validate_region_scope(context)
    return true if user.admin? || user.company_admin?
    
    region_id = context[:region_id]
    return true unless region_id
    
    accessible_region_ids.include?(region_id.to_i)
  end
  
  # Validate location scope
  #
  # @param context [Hash] Must include :location_id
  # @return [Boolean] true if user can access location
  def validate_location_scope(context)
    return true if user.admin? || user.company_admin?
    
    location_id = context[:location_id]
    return true unless location_id
    
    accessible_location_ids.include?(location_id.to_i)
  end
  
  # Validate owner scope
  #
  # @param context [Hash] Must include :owner_id or :user_id
  # @return [Boolean] true if user is the owner
  def validate_owner_scope(context)
    owner_id = context[:owner_id] || context[:user_id]
    return true unless owner_id
    
    user.id == owner_id.to_i
  end
  
  # Generate cache key for permission
  #
  # @param resource_key [String] Resource identifier
  # @param action_key [String] Action identifier
  # @param scope_key [String] Scope identifier
  # @return [String] Cache key
  def permission_cache_key(resource_key, action_key, scope_key)
    "permissions:#{user.id}:#{resource_key}:#{action_key}:#{scope_key}"
  end
end
