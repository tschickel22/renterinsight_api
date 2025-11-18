# frozen_string_literal: true

# RbacMigrationService
#
# Service to enable RBAC system for companies and migrate existing users
# from legacy role system to new RBAC system.
#
# Usage:
#   service = RbacMigrationService.new(company)
#   service.migrate!
#
# Features:
# - Enables RBAC system for company
# - Creates company-specific roles from system defaults
# - Migrates existing users to appropriate RBAC roles
# - Handles location assignments
# - Provides rollback capability
#
# Migration Logic:
# - super_admin/admin → company_admin role
# - staff/employee → company_staff role
# - client/buyer → read_only role (if applicable)
# - Location admins → location_admin role
# - Location managers → location_manager role
# - Location staff → location_staff role

class RbacMigrationService
  attr_reader :company, :errors, :migration_log
  
  def initialize(company)
    @company = company
    @errors = []
    @migration_log = []
  end
  
  # Enable RBAC and migrate all users
  #
  # @return [Boolean] true if successful
  def migrate!
    return false if company.use_rbac_system
    
    ActiveRecord::Base.transaction do
      log "Starting RBAC migration for company #{company.id}: #{company.name}"
      
      # Step 1: Enable RBAC for company
      enable_rbac!
      
      # Step 2: Clone system roles to company (optional, for customization)
      clone_system_roles!
      
      # Step 3: Migrate all users
      migrate_users!
      
      log "RBAC migration completed successfully"
      true
    end
  rescue StandardError => e
    @errors << e.message
    Rails.logger.error "[RbacMigration] Migration failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    false
  end
  
  # Migrate a single user to RBAC
  #
  # @param user [User] User to migrate
  # @return [Boolean] true if successful
  def migrate_user!(user)
    return false unless user.company_id == company.id
    return false if user.uses_rbac?
    
    ActiveRecord::Base.transaction do
      log "Migrating user #{user.id}: #{user.email}"
      
      # Assign company-level role based on legacy role
      assign_company_role(user)
      
      # Assign location-level roles based on UserLocation records
      assign_location_roles(user)
      
      log "User #{user.id} migrated successfully"
      true
    end
  rescue StandardError => e
    @errors << "User #{user.id}: #{e.message}"
    Rails.logger.error "[RbacMigration] User migration failed: #{e.message}"
    false
  end
  
  # Rollback RBAC migration
  #
  # @return [Boolean] true if successful
  def rollback!
    return false unless company.use_rbac_system
    
    ActiveRecord::Base.transaction do
      log "Rolling back RBAC migration for company #{company.id}"
      
      # Remove all user role assignments
      UserRoleAssignment.where(user_id: company.users.pluck(:id)).destroy_all
      
      # Remove company-specific custom roles (keep system roles)
      company.roles.where(is_system_role: false).destroy_all
      
      # Disable RBAC
      company.update!(use_rbac_system: false)
      
      log "RBAC rollback completed"
      true
    end
  rescue StandardError => e
    @errors << e.message
    Rails.logger.error "[RbacMigration] Rollback failed: #{e.message}"
    false
  end
  
  # Test migration without committing (dry run)
  #
  # @return [Hash] Migration plan details
  def test_migration
    plan = {
      company: {
        id: company.id,
        name: company.name,
        current_rbac_status: company.use_rbac_system
      },
      users: [],
      summary: {
        total_users: 0,
        by_legacy_role: {},
        by_target_role: {}
      }
    }
    
    company.users.where(status: 'active').each do |user|
      user_plan = analyze_user_migration(user)
      plan[:users] << user_plan
      plan[:summary][:total_users] += 1
      
      # Count by legacy role
      legacy_role = user.role || 'none'
      plan[:summary][:by_legacy_role][legacy_role] ||= 0
      plan[:summary][:by_legacy_role][legacy_role] += 1
      
      # Count by target RBAC role
      user_plan[:target_roles].each do |role_assignment|
        role_key = role_assignment[:role_key]
        plan[:summary][:by_target_role][role_key] ||= 0
        plan[:summary][:by_target_role][role_key] += 1
      end
    end
    
    plan
  end
  
  private
  
  def enable_rbac!
    company.update!(use_rbac_system: true)
    log "RBAC system enabled for company"
  end
  
  def clone_system_roles!
    log "Cloning system roles to company (optional)"
    
    # Companies can use system roles directly, so this is optional
    # Only clone if company wants to customize roles
    
    # For now, we'll use system roles directly
    # Companies can clone specific roles later via the API if needed
  end
  
  def migrate_users!
    company.users.where(status: 'active').each do |user|
      migrate_user!(user)
    end
  end
  
  def assign_company_role(user)
    role_key = map_legacy_to_rbac_role(user.role)
    role = Role.find_by!(key: role_key, tier: 'company', is_system_role: true)
    
    # Create company-level role assignment
    UserRoleAssignment.find_or_create_by!(
      user: user,
      role: role,
      tier: 'company',
      company_id: company.id
    )
    
    log "  Assigned company role: #{role.name}"
  end
  
  def assign_location_roles(user)
    # Get all location assignments for user
    user.user_locations.where(active: true).each do |user_location|
      role_key = map_location_role_to_rbac(user_location.location_role)
      next unless role_key
      
      role = Role.find_by!(key: role_key, tier: 'location', is_system_role: true)
      
      # Create location-level role assignment
      UserRoleAssignment.find_or_create_by!(
        user: user,
        role: role,
        tier: 'location',
        company_id: company.id,
        location_id: user_location.location_id
      )
      
      log "  Assigned location role: #{role.name} at location #{user_location.location_id}"
    end
  end
  
  def map_legacy_to_rbac_role(legacy_role)
    case legacy_role&.downcase
    when 'super_admin', 'admin', 'tenant'
      'company_admin'
    when 'staff', 'employee', 'manager'
      'company_staff'
    when 'client', 'buyer', 'customer'
      'company_read_only'
    else
      'company_staff' # Default to staff for unknown roles
    end
  end
  
  def map_location_role_to_rbac(location_role)
    case location_role&.downcase
    when 'location_admin'
      'location_admin'
    when 'location_manager'
      'location_manager'
    when 'location_staff'
      'location_staff'
    else
      nil # No location role
    end
  end
  
  def analyze_user_migration(user)
    {
      id: user.id,
      email: user.email,
      name: user.name,
      legacy_role: user.role,
      target_roles: build_target_roles(user)
    }
  end
  
  def build_target_roles(user)
    roles = []
    
    # Company-level role
    role_key = map_legacy_to_rbac_role(user.role)
    role = Role.find_by(key: role_key, tier: 'company', is_system_role: true)
    if role
      roles << {
        role_key: role.key,
        role_name: role.name,
        tier: 'company',
        scope: 'company-wide'
      }
    end
    
    # Location-level roles
    user.user_locations.where(active: true).each do |user_location|
      role_key = map_location_role_to_rbac(user_location.location_role)
      next unless role_key
      
      role = Role.find_by(key: role_key, tier: 'location', is_system_role: true)
      if role
        roles << {
          role_key: role.key,
          role_name: role.name,
          tier: 'location',
          scope: "location #{user_location.location_id}",
          location_id: user_location.location_id
        }
      end
    end
    
    roles
  end
  
  def log(message)
    @migration_log << message
    Rails.logger.info "[RbacMigration] #{message}"
  end
end
