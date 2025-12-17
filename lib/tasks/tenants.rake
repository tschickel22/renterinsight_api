# frozen_string_literal: true

namespace :tenants do
  desc "Fix tenant owners missing company_admin RBAC role assignment"
  task fix_owner_roles: :environment do
    puts "Finding tenant owners without company_admin role..."
    
    fixed_count = 0
    
    # Find all users who are the only user (or admin) of their company but don't have RBAC role
    Company.find_each do |company|
      # Skip companies without users
      users = company.users.where(deleted_at: nil)
      next if users.empty?
      
      # Find the owner (usually the first user or one with role='tenant')
      owner = users.find_by(role: 'tenant') || users.order(:created_at).first
      next unless owner
      
      # Check if owner has company_admin role
      has_admin_role = UserRoleAssignment.joins(:role)
        .where(user_id: owner.id, company_id: company.id)
        .where(roles: { key: 'company_admin', tier: 'company' })
        .exists?
      
      if has_admin_role
        puts "  ✓ #{owner.email} (Company: #{company.name}) - already has company_admin role"
        next
      end
      
      # Find or create company_admin role for this company
      role = Role.find_by(key: 'company_admin', company_id: company.id, tier: 'company')
      role ||= Role.find_by(key: 'company_admin', company_id: nil, tier: 'company') # Platform-wide role
      
      unless role
        puts "  ⚠ Creating company_admin role for #{company.name}..."
        role = Role.create!(
          key: 'company_admin',
          name: 'Company Admin',
          tier: 'company',
          company_id: company.id,
          description: 'Full administrative access to company',
          is_system_role: true,
          is_active: true,
          permissions: { '*' => ['*'] }
        )
      end
      
      # Create the assignment
      assignment = UserRoleAssignment.create!(
        user_id: owner.id,
        role_id: role.id,
        company_id: company.id
      )
      
      puts "  ✓ Assigned company_admin role to #{owner.email} (Company: #{company.name})"
      fixed_count += 1
    end
    
    puts "\nFixed #{fixed_count} tenant owners."
  end
  
  desc "Assign company_admin role to a specific user"
  task :assign_admin_role, [:user_id, :company_id] => :environment do |t, args|
    user_id = args[:user_id]
    company_id = args[:company_id]
    
    unless user_id && company_id
      puts "Usage: rails tenants:assign_admin_role[user_id,company_id]"
      puts "Example: rails tenants:assign_admin_role[33,20]"
      exit 1
    end
    
    user = User.find(user_id)
    company = Company.find(company_id)
    
    puts "Assigning company_admin role to #{user.email} for #{company.name}..."
    
    # Find or create company_admin role
    role = Role.find_by(key: 'company_admin', company_id: company.id, tier: 'company')
    role ||= Role.find_by(key: 'company_admin', company_id: nil, tier: 'company')
    
    unless role
      role = Role.create!(
        key: 'company_admin',
        name: 'Company Admin',
        tier: 'company',
        company_id: company.id,
        description: 'Full administrative access to company',
        is_system_role: true,
        is_active: true,
        permissions: { '*' => ['*'] }
      )
      puts "Created company_admin role for #{company.name}"
    end
    
    # Check existing assignment
    existing = UserRoleAssignment.find_by(
      user_id: user.id,
      role_id: role.id,
      company_id: company.id
    )
    
    if existing
      puts "User already has company_admin role!"
    else
      UserRoleAssignment.create!(
        user_id: user.id,
        role_id: role.id,
        company_id: company.id
      )
      puts "✓ Assigned company_admin role to #{user.email}"
    end
  end
end
