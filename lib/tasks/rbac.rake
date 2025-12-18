# frozen_string_literal: true

namespace :rbac do
  desc 'Reseed all system role permissions (safe to run multiple times)'
  task reseed_permissions: :environment do
    puts "🔄 Reseeding RBAC permissions for system roles..."
    puts "="*80
    
    # Check that resources, actions, and scopes exist
    if Resource.count.zero? || Action.count.zero? || Scope.count.zero?
      puts "❌ ERROR: Resources, Actions, or Scopes are missing!"
      puts "   Run: rails db:seed first"
      exit 1
    end
    
    system_roles = Role.system_roles.order(:tier, :name)
    
    if system_roles.empty?
      puts "❌ ERROR: No system roles found!"
      puts "   Run: rails db:seed first"
      exit 1
    end
    
    puts "\n📊 Found #{system_roles.count} system roles:"
    system_roles.each do |role|
      puts "   - #{role.name} (#{role.tier})"
    end
    
    puts "\n🔐 Granting permissions..."
    
    system_roles.each do |role|
      # Clear existing permissions for this role
      old_count = role.role_permissions.count
      role.role_permissions.destroy_all
      
      # Grant permissions based on role key
      case role.key
      when 'company_admin'
        Role.send(:grant_full_permissions!, role)
      when 'company_manager'
        Role.send(:grant_manager_permissions!, role)
      when 'company_staff'
        Role.send(:grant_staff_permissions!, role)
      when 'company_read_only'
        Role.send(:grant_read_only_permissions!, role)
      when 'location_admin'
        Role.send(:grant_location_admin_permissions!, role)
      when 'location_manager'
        Role.send(:grant_location_manager_permissions!, role)
      when 'location_staff'
        Role.send(:grant_location_staff_permissions!, role)
      when 'service_tech'
        Role.send(:grant_service_tech_permissions!, role)
      when 'sales_rep'
        Role.send(:grant_sales_rep_permissions!, role)
      when 'finance_staff'
        Role.send(:grant_finance_staff_permissions!, role)
      when 'crm_specialist'
        Role.send(:grant_crm_specialist_permissions!, role)
      when 'inventory_manager'
        Role.send(:grant_inventory_manager_permissions!, role)
      else
        puts "   ⚠️  Unknown role key: #{role.key} - skipping"
        next
      end
      
      new_count = role.role_permissions.count
      puts "   ✅ #{role.name}: #{old_count} → #{new_count} permissions"
    end
    
    puts "\n" + "="*80
    puts "✨ Permission reseeding complete!"
    puts "="*80
    puts "\n📊 Final Summary:"
    puts "   Total RolePermissions: #{RolePermission.count}"
    puts "\n🎉 Permissions per role:"
    Role.system_roles.order(:tier, :name).each do |role|
      puts "   - #{role.name}: #{role.role_permissions.count} permissions"
    end
    puts "="*80
  end
  
  desc 'Show current RBAC system status'
  task status: :environment do
    puts "📊 RBAC System Status"
    puts "="*80
    puts "Resources: #{Resource.count}"
    puts "Actions: #{Action.count}"
    puts "Scopes: #{Scope.count}"
    puts "System Roles: #{Role.system_roles.count}"
    puts "Custom Roles: #{Role.custom_roles.count}"
    puts "Total RolePermissions: #{RolePermission.count}"
    puts "\n🎭 System Roles:"
    Role.system_roles.order(:tier, :name).each do |role|
      puts "   - #{role.name} (#{role.tier}): #{role.role_permissions.count} permissions"
    end
    puts "="*80
  end
  
  desc 'Full RBAC system reset (WARNING: Destructive!)'
  task reset: :environment do
    puts "⚠️  WARNING: This will destroy ALL RBAC data and reseed!"
    puts "Press Ctrl+C to cancel, or press Enter to continue..."
    STDIN.gets
    
    puts "\n🗑️  Destroying existing data..."
    RolePermission.destroy_all
    Role.destroy_all
    Resource.destroy_all
    Action.destroy_all
    Scope.destroy_all
    
    puts "🌱 Reseeding RBAC system..."
    load Rails.root.join('db', 'seeds', 'rbac_system_seed.rb')
    
    puts "\n✅ RBAC system reset complete!"
  end
end
