# frozen_string_literal: true

namespace :rbac do
  desc "Diagnose RBAC system state - check roles, permissions, and user assignments"
  task diagnose: :environment do
    puts "=" * 80
    puts "RBAC System Diagnostic Report"
    puts "Generated: #{Time.current}"
    puts "=" * 80

    # 1. Check if system roles exist
    puts "\n📋 SYSTEM ROLES"
    puts "-" * 40
    
    expected_roles = %w[
      company_admin
      company_manager
      company_staff
      company_read_only
      location_admin
      location_manager
      location_staff
    ]
    
    expected_roles.each do |key|
      role = Role.find_by(key: key, is_system_role: true)
      if role
        perm_count = role.role_permissions.count
        puts "  ✅ #{key}: #{role.name} (#{perm_count} permissions)"
      else
        puts "  ❌ #{key}: MISSING!"
      end
    end

    # 2. Check resources, actions, scopes
    puts "\n📦 RBAC COMPONENTS"
    puts "-" * 40
    puts "  Resources: #{Resource.count}"
    puts "  Actions: #{Action.count}"
    puts "  Scopes: #{Scope.count}"
    puts "  Total Role Permissions: #{RolePermission.count}"

    # 3. Check companies with RBAC enabled
    puts "\n🏢 COMPANIES WITH RBAC ENABLED"
    puts "-" * 40
    
    Company.where(use_rbac_system: true).each do |company|
      users_count = company.users.count
      users_with_rbac = company.users.joins(:user_role_assignments).distinct.count
      puts "\n  #{company.name} (ID: #{company.id})"
      puts "    Users: #{users_count} total, #{users_with_rbac} with RBAC assignments"
      puts "    Missing RBAC: #{users_count - users_with_rbac} users"
      
      # Show users without RBAC assignments
      users_without_rbac = company.users.left_joins(:user_role_assignments)
                                  .where(user_role_assignments: { id: nil })
      
      if users_without_rbac.any?
        puts "    ⚠️  Users needing sync:"
        users_without_rbac.each do |user|
          puts "      - #{user.email} (legacy role: #{user.role || 'nil'})"
        end
      end
    end

    # 4. Check specific test user
    puts "\n👤 TEST USER: t+rg1@renterinsight.com"
    puts "-" * 40
    
    test_user = User.find_by(email: 't+rg1@renterinsight.com')
    if test_user
      puts "  User ID: #{test_user.id}"
      puts "  Company ID: #{test_user.company_id}"
      puts "  Legacy role field: #{test_user.role.inspect}"
      puts "  Status: #{test_user.status}"
      
      puts "\n  RBAC Assignments:"
      if test_user.user_role_assignments.any?
        test_user.user_role_assignments.includes(:role).each do |assignment|
          role_name = assignment.role&.name || 'ROLE NOT FOUND'
          role_key = assignment.role&.key || 'N/A'
          puts "    - #{role_name} (#{role_key})"
          puts "      Tier: #{assignment.tier}, Company: #{assignment.company_id}"
          puts "      Assigned at: #{assignment.assigned_at}"
        end
      else
        puts "    ⚠️  NO RBAC ASSIGNMENTS!"
      end
      
      # Test permission check
      puts "\n  Permission Test (brochures:read):"
      can_read = test_user.has_permission?('brochures', 'read', 'all', test_user.company_id)
      puts "    Result: #{can_read ? '✅ GRANTED' : '❌ DENIED'}"
      
      can_create = test_user.has_permission?('brochures', 'create', 'all', test_user.company_id)
      puts "  Permission Test (brochures:create):"
      puts "    Result: #{can_create ? '✅ GRANTED' : '❌ DENIED'}"
    else
      puts "  ❌ User not found!"
    end

    # 5. Role mapping test
    puts "\n🔄 ROLE MAPPING TEST"
    puts "-" * 40
    
    test_mappings = {
      'Read-Only User' => 'company_read_only',
      'Company Staff' => 'company_staff',
      'Company Manager' => 'company_manager',
      'Company Administrator' => 'company_admin'
    }
    
    test_mappings.each do |legacy_name, expected_key|
      role = Role.find_by(key: expected_key)
      if role
        puts "  '#{legacy_name}' → #{expected_key}: ✅ Found (#{role.name})"
      else
        puts "  '#{legacy_name}' → #{expected_key}: ❌ MISSING!"
      end
    end

    # 6. Show Read-Only permissions in detail
    puts "\n📜 READ-ONLY ROLE PERMISSIONS"
    puts "-" * 40
    
    read_only_role = Role.find_by(key: 'company_read_only')
    if read_only_role
      read_only_role.role_permissions.includes(:resource, :action, :scope).each do |perm|
        next unless perm.granted
        puts "  #{perm.resource.key}:#{perm.action.key}:#{perm.scope.key}"
      end
    end

    puts "\n" + "=" * 80
    puts "END OF DIAGNOSTIC REPORT"
    puts "=" * 80
  end

  desc "Sync all users' RBAC assignments to match their legacy role field"
  task sync_all: :environment do
    puts "=" * 80
    puts "RBAC Sync - Matching RBAC assignments to legacy role field"
    puts "=" * 80

    synced = 0
    failed = 0
    skipped = 0

    Company.where(use_rbac_system: true).each do |company|
      puts "\n🏢 Processing: #{company.name} (ID: #{company.id})"
      
      company.users.each do |user|
        next if user.role.blank?
        
        # Get current RBAC role
        current_assignment = user.user_role_assignments.find_by(company_id: company.id, tier: 'company')
        current_role_key = current_assignment&.role&.key
        
        # Map legacy role to expected RBAC key
        expected_key = case user.role
                      when 'Read-Only User', 'company_read_only', 'read_only'
                        'company_read_only'
                      when 'Company Staff', 'company_staff', 'staff'
                        'company_staff'
                      when 'Company Manager', 'company_manager', 'manager'
                        'company_manager'
                      when 'Company Administrator', 'company_admin', 'admin'
                        'company_admin'
                      else
                        nil
                      end
        
        if expected_key.nil?
          puts "  ⏭️  #{user.email}: Unknown role '#{user.role}', skipping"
          skipped += 1
          next
        end
        
        if current_role_key == expected_key
          puts "  ✅ #{user.email}: Already synced (#{expected_key})"
          skipped += 1
          next
        end
        
        # Sync the role
        result = user.replace_rbac_role(expected_key, company_id: company.id)
        
        if result
          puts "  🔄 #{user.email}: #{current_role_key || 'none'} → #{expected_key}"
          synced += 1
        else
          puts "  ❌ #{user.email}: Failed to sync to #{expected_key}"
          failed += 1
        end
      end
    end

    puts "\n" + "=" * 80
    puts "SUMMARY"
    puts "  Synced: #{synced}"
    puts "  Skipped: #{skipped}"
    puts "  Failed: #{failed}"
    puts "=" * 80
  end
end
