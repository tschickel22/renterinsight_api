# frozen_string_literal: true

namespace :rbac do
  desc "Assign RBAC roles to existing users based on their legacy role field"
  task assign_roles_to_existing_users: :environment do
    puts "=" * 80
    puts "RBAC Role Assignment for Existing Users"
    puts "=" * 80
    
    # Get companies with RBAC enabled
    companies_with_rbac = Company.where(use_rbac_system: true)
    
    if companies_with_rbac.empty?
      puts "\n⚠️  No companies have RBAC system enabled."
      puts "To enable RBAC for a company, run:"
      puts "  Company.find(ID).update!(use_rbac_system: true)"
      puts "\nOr to enable for all companies:"
      puts "  Company.update_all(use_rbac_system: true)"
      return
    end
    
    puts "\nFound #{companies_with_rbac.count} company(ies) with RBAC enabled:"
    companies_with_rbac.each do |company|
      puts "  - #{company.name} (ID: #{company.id})"
    end
    
    total_assigned = 0
    total_skipped = 0
    total_failed = 0
    
    companies_with_rbac.each do |company|
      puts "\n" + "-" * 60
      puts "Processing company: #{company.name} (ID: #{company.id})"
      puts "-" * 60
      
      users = company.users.where.not(role: nil)
      
      users.each do |user|
        # Check if user already has RBAC assignment for this company
        existing_assignment = user.user_role_assignments.find_by(company_id: company.id)
        
        if existing_assignment
          puts "  ⏭️  #{user.email} - already has role: #{existing_assignment.role&.name}"
          total_skipped += 1
          next
        end
        
        # Assign role based on legacy role field
        assignment = user.assign_rbac_role(
          user.role,
          company_id: company.id
        )
        
        if assignment
          puts "  ✅ #{user.email} - assigned role: #{assignment.role&.name} (#{assignment.role&.key})"
          total_assigned += 1
        else
          puts "  ❌ #{user.email} - failed to assign role '#{user.role}'"
          total_failed += 1
        end
      end
    end
    
    puts "\n" + "=" * 80
    puts "SUMMARY"
    puts "=" * 80
    puts "  Assigned: #{total_assigned}"
    puts "  Skipped (already assigned): #{total_skipped}"
    puts "  Failed: #{total_failed}"
    puts "=" * 80
  end
  
  desc "List all users and their RBAC role assignments"
  task list_user_roles: :environment do
    puts "=" * 80
    puts "RBAC Role Assignments by Company"
    puts "=" * 80
    
    Company.where(use_rbac_system: true).each do |company|
      puts "\n#{company.name} (ID: #{company.id})"
      puts "-" * 60
      
      company.users.includes(:user_role_assignments => :role).each do |user|
        assignments = user.user_role_assignments.where(company_id: company.id)
        
        if assignments.any?
          assignments.each do |assignment|
            role_name = assignment.role&.name || 'Unknown Role'
            puts "  #{user.email} (#{user.role}) => #{role_name} [tier: #{assignment.tier}]"
          end
        else
          puts "  #{user.email} (#{user.role}) => NO RBAC ASSIGNMENT ⚠️"
        end
      end
    end
  end
  
  desc "Enable RBAC system for a specific company"
  task :enable_for_company, [:company_id] => :environment do |t, args|
    company_id = args[:company_id]
    
    unless company_id
      puts "Usage: rake rbac:enable_for_company[COMPANY_ID]"
      exit 1
    end
    
    company = Company.find_by(id: company_id)
    
    unless company
      puts "❌ Company with ID #{company_id} not found"
      exit 1
    end
    
    if company.use_rbac_system
      puts "ℹ️  RBAC is already enabled for #{company.name}"
    else
      company.update!(use_rbac_system: true)
      puts "✅ RBAC system enabled for #{company.name}"
    end
    
    # Also assign roles to existing users
    Rake::Task['rbac:assign_roles_to_existing_users'].invoke
  end
  
  desc "Fix read-only role permissions to use 'all' scope instead of 'assigned_locations'"
  task fix_read_only_permissions: :environment do
    puts "=" * 80
    puts "Fixing Read-Only Role Permissions"
    puts "=" * 80
    
    read_only_role = Role.find_by(key: 'company_read_only')
    
    unless read_only_role
      puts "❌ company_read_only role not found. Run RBAC seeds first."
      exit 1
    end
    
    all_scope = Scope.find_by(key: 'all')
    assigned_locations_scope = Scope.find_by(key: 'assigned_locations')
    read_action = Action.find_by(key: 'read')
    
    unless all_scope && read_action
      puts "❌ Required scope/action not found. Run RBAC seeds first."
      exit 1
    end
    
    # Find all read-only permissions with assigned_locations scope
    permissions_to_fix = read_only_role.role_permissions
                          .where(action: read_action, scope: assigned_locations_scope)
    
    puts "\nFound #{permissions_to_fix.count} permissions with 'assigned_locations' scope"
    
    fixed_count = 0
    permissions_to_fix.each do |permission|
      # Check if 'all' scope permission already exists
      existing = read_only_role.role_permissions.find_by(
        resource: permission.resource,
        action: read_action,
        scope: all_scope
      )
      
      if existing
        puts "  ⏭️  #{permission.resource.key}:read:all - already exists"
        permission.destroy # Remove the duplicate assigned_locations one
      else
        permission.update!(scope: all_scope)
        puts "  ✅ #{permission.resource.key}:read - changed to 'all' scope"
        fixed_count += 1
      end
    end
    
    puts "\n" + "=" * 80
    puts "SUMMARY: Fixed #{fixed_count} permissions"
    puts "Read-Only users can now view all company data."
    puts "=" * 80
  end
  
  desc "Assign RBAC role to a specific user"
  task :assign_role, [:user_email, :role_key] => :environment do |t, args|
    user_email = args[:user_email]
    role_key = args[:role_key]
    
    unless user_email && role_key
      puts "Usage: rake rbac:assign_role[user@email.com,role_key]"
      puts "\nAvailable role keys:"
      Role.system_roles.active.each do |role|
        puts "  - #{role.key}: #{role.name}"
      end
      exit 1
    end
    
    user = User.find_by(email: user_email)
    
    unless user
      puts "❌ User with email #{user_email} not found"
      exit 1
    end
    
    unless user.company_id
      puts "❌ User #{user_email} has no company assigned"
      exit 1
    end
    
    company = Company.find(user.company_id)
    
    unless company.use_rbac_system
      puts "⚠️  Company #{company.name} does not have RBAC enabled. Enabling now..."
      company.update!(use_rbac_system: true)
    end
    
    assignment = user.replace_rbac_role(role_key, company_id: company.id)
    
    if assignment
      puts "✅ Assigned role '#{assignment.role.name}' to #{user_email}"
    else
      puts "❌ Failed to assign role '#{role_key}' to #{user_email}"
    end
  end
end
