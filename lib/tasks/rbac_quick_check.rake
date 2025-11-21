# frozen_string_literal: true

namespace :rbac do
  desc "Quick check of a specific user's RBAC state"
  task :check_user, [:email] => :environment do |t, args|
    email = args[:email] || 't+rg1@renterinsight.com'
    
    user = User.find_by(email: email)
    unless user
      puts "❌ User not found: #{email}"
      exit 1
    end

    puts "=" * 60
    puts "RBAC State for: #{email}"
    puts "=" * 60
    puts ""
    puts "User ID: #{user.id}"
    puts "Company ID: #{user.company_id}"
    puts ""
    puts "📋 LEGACY ROLE FIELD:"
    puts "   #{user.role.inspect}"
    puts ""
    puts "🔐 RBAC ASSIGNMENTS:"
    
    if user.user_role_assignments.any?
      user.user_role_assignments.includes(:role).each do |assignment|
        role = assignment.role
        puts "   - Role ID: #{assignment.role_id}"
        puts "     Role Key: #{role&.key || 'N/A'}"
        puts "     Role Name: #{role&.name || 'ROLE NOT FOUND'}"
        puts "     Tier: #{assignment.tier}"
        puts "     Company ID: #{assignment.company_id}"
        puts "     Assigned At: #{assignment.assigned_at}"
        puts ""
      end
    else
      puts "   ⚠️  NO RBAC ASSIGNMENTS!"
    end
    
    # Check if they match
    legacy = user.role
    rbac_role = user.user_role_assignments.find_by(company_id: user.company_id, tier: 'company')&.role
    
    puts "=" * 60
    puts "SYNC STATUS:"
    puts "=" * 60
    puts ""
    puts "Legacy Role: #{legacy.inspect}"
    puts "RBAC Role:   #{rbac_role&.name.inspect} (#{rbac_role&.key.inspect})"
    
    # Map legacy to expected RBAC key
    expected_key = case legacy
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
    
    if rbac_role&.key == expected_key
      puts ""
      puts "✅ SYNCED - Legacy and RBAC roles match!"
    else
      puts ""
      puts "❌ MISMATCH!"
      puts "   Expected RBAC key: #{expected_key.inspect}"
      puts "   Actual RBAC key:   #{rbac_role&.key.inspect}"
    end
    
    puts ""
    puts "=" * 60
  end
end
