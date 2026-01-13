# frozen_string_literal: true

# Add Calendar Resource to RBAC
# 
# This migration adds the calendar resource with calendar-specific actions
# to enable role-based access control for calendar and scheduling features.
# 
# Calendar Actions:
# - view_own: View personal calendar
# - view_team: View team calendars (location/company based on scope)
# - view_all: View all company calendars
# - view_service_all: View all service tickets in calendar
# - view_service_unassigned: View unassigned service tickets
# - manage_schedule: Reschedule activities (future enhancement)

class AddCalendarResourceToRbac < ActiveRecord::Migration[8.0]
  def up
    # Create calendar resource
    calendar_resource = Resource.find_or_create_by!(key: 'calendar') do |r|
      r.name = 'Calendar'
      r.description = 'Calendar and scheduling functionality'
      r.category = 'core'
      r.active = true
    end
    
    puts "✅ Created 'calendar' resource"
    
    # Create calendar-specific actions
    create_calendar_actions
    
    # Grant permissions to existing system roles
    grant_permissions_to_system_roles(calendar_resource)
  end
  
  def down
    # Remove calendar-specific actions
    %w[view_own view_team view_all view_service_all view_service_unassigned manage_schedule].each do |action_key|
      Action.find_by(key: action_key)&.destroy
    end
    
    # Remove calendar resource (cascade delete will handle permissions)
    Resource.find_by(key: 'calendar')&.destroy
    puts "❌ Removed 'calendar' resource and actions"
  end
  
  private
  
  def create_calendar_actions
    calendar_actions = [
      { key: 'view_own', name: 'View Own Calendar', description: 'View personal calendar and activities' },
      { key: 'view_team', name: 'View Team Calendar', description: 'View calendars of team members' },
      { key: 'view_all', name: 'View All Calendars', description: 'View all company calendars' },
      { key: 'view_service_all', name: 'View All Service Tickets', description: 'View all service tickets in calendar' },
      { key: 'view_service_unassigned', name: 'View Unassigned Tickets', description: 'View unassigned service tickets' },
      { key: 'manage_schedule', name: 'Manage Schedule', description: 'Reschedule activities and manage calendar items' }
    ]
    
    calendar_actions.each do |action_data|
      Action.find_or_create_by!(key: action_data[:key]) do |action|
        action.name = action_data[:name]
        action.description = action_data[:description]
      end
      puts "  ✅ Created action: #{action_data[:key]}"
    end
  end
  
  def grant_permissions_to_system_roles(calendar_resource)
    # Get scopes
    all_scope = Scope.find_by!(key: 'all')
    assigned_locations_scope = Scope.find_by!(key: 'assigned_locations')
    own_scope = Scope.find_by!(key: 'own')
    
    # Get calendar actions
    view_own_action = Action.find_by!(key: 'view_own')
    view_team_action = Action.find_by!(key: 'view_team')
    view_all_action = Action.find_by!(key: 'view_all')
    view_service_all_action = Action.find_by!(key: 'view_service_all')
    view_service_unassigned_action = Action.find_by!(key: 'view_service_unassigned')
    manage_schedule_action = Action.find_by!(key: 'manage_schedule')
    
    # ==========================================
    # COMPANY ADMINISTRATOR - Full Access
    # ==========================================
    company_admin = Role.system_roles.find_by(key: 'company_admin')
    if company_admin
      [view_own_action, view_team_action, view_all_action, view_service_all_action, 
       view_service_unassigned_action, manage_schedule_action].each do |action|
        RolePermission.find_or_create_by!(
          role: company_admin,
          resource: calendar_resource,
          action: action,
          scope: all_scope,
          granted: true
        )
      end
      puts "  ✅ Granted full calendar permissions to Company Administrator"
    end
    
    # ==========================================
    # COMPANY MANAGER - Team + Service View
    # ==========================================
    company_manager = Role.system_roles.find_by(key: 'company_manager')
    if company_manager
      # Can view own, team, and all service tickets
      [view_own_action, view_team_action, view_service_all_action, 
       view_service_unassigned_action].each do |action|
        scope = (action == view_own_action) ? own_scope : assigned_locations_scope
        RolePermission.find_or_create_by!(
          role: company_manager,
          resource: calendar_resource,
          action: action,
          scope: scope,
          granted: true
        )
      end
      puts "  ✅ Granted team calendar permissions to Company Manager"
    end
    
    # ==========================================
    # COMPANY STAFF - Own Calendar Only
    # ==========================================
    company_staff = Role.system_roles.find_by(key: 'company_staff')
    if company_staff
      RolePermission.find_or_create_by!(
        role: company_staff,
        resource: calendar_resource,
        action: view_own_action,
        scope: own_scope,
        granted: true
      )
      puts "  ✅ Granted own calendar permissions to Company Staff"
    end
    
    # ==========================================
    # READ-ONLY USER - Own Calendar Only
    # ==========================================
    company_read_only = Role.system_roles.find_by(key: 'company_read_only')
    if company_read_only
      RolePermission.find_or_create_by!(
        role: company_read_only,
        resource: calendar_resource,
        action: view_own_action,
        scope: own_scope,
        granted: true
      )
      puts "  ✅ Granted own calendar permissions to Read-Only User"
    end
    
    # ==========================================
    # LOCATION ADMINISTRATOR - Team + Service
    # ==========================================
    location_admin = Role.system_roles.find_by(key: 'location_admin')
    if location_admin
      [view_own_action, view_team_action, view_service_all_action, 
       view_service_unassigned_action, manage_schedule_action].each do |action|
        scope = (action == view_own_action) ? own_scope : assigned_locations_scope
        RolePermission.find_or_create_by!(
          role: location_admin,
          resource: calendar_resource,
          action: action,
          scope: scope,
          granted: true
        )
      end
      puts "  ✅ Granted team calendar permissions to Location Administrator"
    end
    
    # ==========================================
    # LOCATION MANAGER - Team + Service
    # ==========================================
    location_manager = Role.system_roles.find_by(key: 'location_manager')
    if location_manager
      [view_own_action, view_team_action, view_service_all_action, 
       view_service_unassigned_action].each do |action|
        scope = (action == view_own_action) ? own_scope : assigned_locations_scope
        RolePermission.find_or_create_by!(
          role: location_manager,
          resource: calendar_resource,
          action: action,
          scope: scope,
          granted: true
        )
      end
      puts "  ✅ Granted team calendar permissions to Location Manager"
    end
    
    # ==========================================
    # LOCATION STAFF - Own Calendar Only
    # ==========================================
    location_staff = Role.system_roles.find_by(key: 'location_staff')
    if location_staff
      RolePermission.find_or_create_by!(
        role: location_staff,
        resource: calendar_resource,
        action: view_own_action,
        scope: own_scope,
        granted: true
      )
      puts "  ✅ Granted own calendar permissions to Location Staff"
    end
    
    # ==========================================
    # SERVICE TECHNICIAN - Own + Service Tickets
    # ==========================================
    service_tech = Role.system_roles.find_by(key: 'service_tech')
    if service_tech
      [view_own_action, view_service_all_action, 
       view_service_unassigned_action, manage_schedule_action].each do |action|
        scope = (action == view_own_action) ? own_scope : assigned_locations_scope
        RolePermission.find_or_create_by!(
          role: service_tech,
          resource: calendar_resource,
          action: action,
          scope: scope,
          granted: true
        )
      end
      puts "  ✅ Granted service calendar permissions to Service Technician"
    end
    
    # ==========================================
    # SALES REPRESENTATIVE - Own + Team
    # ==========================================
    sales_rep = Role.system_roles.find_by(key: 'sales_rep')
    if sales_rep
      [view_own_action, view_team_action].each do |action|
        scope = (action == view_own_action) ? own_scope : assigned_locations_scope
        RolePermission.find_or_create_by!(
          role: sales_rep,
          resource: calendar_resource,
          action: action,
          scope: scope,
          granted: true
        )
      end
      puts "  ✅ Granted team calendar permissions to Sales Representative"
    end
    
    # ==========================================
    # FINANCE STAFF - Own Calendar Only
    # ==========================================
    finance_staff = Role.system_roles.find_by(key: 'finance_staff')
    if finance_staff
      RolePermission.find_or_create_by!(
        role: finance_staff,
        resource: calendar_resource,
        action: view_own_action,
        scope: own_scope,
        granted: true
      )
      puts "  ✅ Granted own calendar permissions to Finance Staff"
    end
    
    # ==========================================
    # CRM SPECIALIST - Own + Team
    # ==========================================
    crm_specialist = Role.system_roles.find_by(key: 'crm_specialist')
    if crm_specialist
      [view_own_action, view_team_action].each do |action|
        scope = (action == view_own_action) ? own_scope : assigned_locations_scope
        RolePermission.find_or_create_by!(
          role: crm_specialist,
          resource: calendar_resource,
          action: action,
          scope: scope,
          granted: true
        )
      end
      puts "  ✅ Granted team calendar permissions to CRM Specialist"
    end
    
    # ==========================================
    # INVENTORY MANAGER - Own + Team
    # ==========================================
    inventory_manager = Role.system_roles.find_by(key: 'inventory_manager')
    if inventory_manager
      [view_own_action, view_team_action].each do |action|
        scope = (action == view_own_action) ? own_scope : assigned_locations_scope
        RolePermission.find_or_create_by!(
          role: inventory_manager,
          resource: calendar_resource,
          action: action,
          scope: scope,
          granted: true
        )
      end
      puts "  ✅ Granted team calendar permissions to Inventory Manager"
    end
    
    puts "\n📊 Calendar Resource Summary:"
    puts "  Total Permissions Created: #{RolePermission.where(resource: calendar_resource).count}"
    puts "  Total Calendar Actions: #{Action.where(key: %w[view_own view_team view_all view_service_all view_service_unassigned manage_schedule]).count}"
  end
end
