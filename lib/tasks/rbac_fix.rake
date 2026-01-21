# frozen_string_literal: true

namespace :rbac do
  desc "Fix NULL company_id on user_role_assignments by backfilling from user's company"
  task fix_company_ids: :environment do
    puts "🔍 Finding user_role_assignments with NULL company_id..."
    
    null_assignments = UserRoleAssignment.where(company_id: nil)
    count = null_assignments.count
    
    if count == 0
      puts "✅ No user_role_assignments with NULL company_id found. All good!"
      exit
    end
    
    puts "⚠️  Found #{count} assignments with NULL company_id"
    
    fixed = 0
    errors = 0
    
    null_assignments.find_each do |assignment|
      user = assignment.user
      
      if user.nil?
        puts "  ❌ Assignment #{assignment.id}: User not found"
        errors += 1
        next
      end
      
      if user.company_id.nil?
        puts "  ❌ Assignment #{assignment.id}: User #{user.id} (#{user.email}) has no company_id"
        errors += 1
        next
      end
      
      puts "  🔄 Fixing assignment #{assignment.id} for user #{user.email}: setting company_id to #{user.company_id}"
      assignment.update!(company_id: user.company_id)
      fixed += 1
    end
    
    puts ""
    puts "=" * 50
    puts "✅ Fixed: #{fixed}"
    puts "❌ Errors: #{errors}"
    puts "=" * 50
  end
  
  desc "Debug RBAC permissions for a user"
  task :debug_user, [:email] => :environment do |t, args|
    email = args[:email]
    
    if email.blank?
      puts "Usage: rake rbac:debug_user[user@example.com]"
      exit 1
    end
    
    user = User.find_by(email: email)
    
    if user.nil?
      puts "❌ User not found: #{email}"
      exit 1
    end
    
    company = user.company
    
    puts "=" * 60
    puts "User: #{user.email} (ID: #{user.id})"
    puts "Company: #{company&.name} (ID: #{company&.id})"
    puts "Legacy Role: #{user.role}"
    puts "Uses RBAC: #{user.uses_rbac?}"
    puts "Company Admin: #{user.company_admin?}"
    puts "Effective Admin: #{user.effective_admin?}"
    puts "=" * 60
    puts ""
    
    puts "📋 User Role Assignments:"
    puts "-" * 60
    
    user.user_role_assignments.includes(:role).each do |assignment|
      status = assignment.active? ? "✅" : "❌"
      puts "  #{status} Role: #{assignment.role&.name} (#{assignment.role&.key})"
      puts "     - Assignment ID: #{assignment.id}"
      puts "     - Company ID: #{assignment.company_id.inspect}"
      puts "     - Tier: #{assignment.tier}"
      puts "     - Location ID: #{assignment.location_id.inspect}"
      puts "     - Expires At: #{assignment.expires_at.inspect}"
      puts ""
    end
    
    puts "🔐 Permissions via RBAC:"
    puts "-" * 60
    
    if company
      permissions = user.rbac_permissions_cache(company.id)
      
      if permissions.empty?
        puts "  ⚠️  No permissions found!"
      else
        # Group by resource
        by_resource = permissions.group_by { |p| p[:resource] }
        by_resource.sort.each do |resource, perms|
          actions = perms.map { |p| p[:action] }.uniq.sort.join(", ")
          puts "  #{resource}: #{actions}"
        end
      end
    else
      puts "  ⚠️  User has no company!"
    end
    
    puts ""
    puts "=" * 60
  end
  
  desc "Assign company_admin role to a user"
  task :make_company_admin, [:email] => :environment do |t, args|
    email = args[:email]
    
    if email.blank?
      puts "Usage: rake rbac:make_company_admin[user@example.com]"
      exit 1
    end
    
    user = User.find_by(email: email)
    
    if user.nil?
      puts "❌ User not found: #{email}"
      exit 1
    end
    
    company = user.company
    
    unless company
      puts "❌ User has no company!"
      exit 1
    end
    
    role = Role.find_by(key: 'company_admin')
    
    unless role
      puts "❌ company_admin role not found! Creating..."
      role = Role.create!(
        key: 'company_admin',
        name: 'Company Administrator',
        tier: 'company',
        description: 'Full access to all company data and settings',
        is_system_role: true,
        active: true
      )
      puts "✅ Created company_admin role"
    end
    
    existing = user.user_role_assignments.find_by(role_id: role.id, company_id: company.id)
    
    if existing
      puts "⚠️  User already has company_admin role for this company"
      puts "  Assignment ID: #{existing.id}"
      puts "  Company ID: #{existing.company_id}"
      puts "  Active: #{existing.active?}"
      exit 0
    end
    
    assignment = UserRoleAssignment.create!(
      user: user,
      role: role,
      company_id: company.id,
      tier: 'company',
      assigned_at: Time.current
    )
    
    puts "✅ Assigned company_admin role to #{email}"
    puts "  Assignment ID: #{assignment.id}"
    puts "  Company: #{company.name} (ID: #{company.id})"
  end
end
