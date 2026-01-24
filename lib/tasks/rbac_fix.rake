# frozen_string_literal: true

namespace :rbac do
  desc "Fix resources: add documents, rename listings to Property Listings & Brochures"
  task fix_resources: :environment do
    puts "=" * 60
    puts "Fixing RBAC Resources"
    puts "=" * 60
    
    # 1. Create documents resource if it doesn't exist
    docs = Resource.find_by(key: 'documents')
    if docs
      puts "Documents resource already exists (ID: #{docs.id})"
    else
      docs = Resource.create(
        key: 'documents',
        name: 'Documents',
        category: 'operations',
        description: 'Manage client documents and file uploads',
        active: true
      )
      puts "Created documents resource (ID: #{docs.id})"
    end
    
    # 2. Add documents permissions to all roles that have other permissions
    puts ""
    puts "Adding documents permissions to existing roles..."
    all_scope = Scope.find_by(key: 'all')
    
    Role.where(active: true).each do |role|
      # If role has any permissions, give it documents permissions too
      if role.role_permissions.granted.any?
        Action.all.each do |action|
          perm = RolePermission.find_or_initialize_by(
            role: role,
            resource: docs,
            action: action,
            scope: all_scope
          )
          perm.granted = true
          if perm.new_record?
            perm.save
            puts "  Added documents:#{action.key} to #{role.name}"
          end
        end
      end
    end
    
    # 3. Rename listings resource
    listings = Resource.find_by(key: 'listings')
    if listings
      old_name = listings.name
      listings.update(name: 'Property Listings & Brochures')
      puts ""
      puts "Renamed '#{old_name}' to '#{listings.name}'"
    else
      puts ""
      puts "WARNING: listings resource not found"
    end
    
    puts ""
    puts "=" * 60
    puts "Done"
    puts "=" * 60
  end
  
  desc "Debug user permissions"
  task :debug, [:email] => :environment do |t, args|
    email = args[:email]
    unless email
      puts "Usage: rake rbac:debug[email@example.com]"
      exit 1
    end
    
    u = User.find_by(email: email)
    unless u
      puts "User not found: #{email}"
      exit 1
    end
    
    puts "=" * 60
    puts "User: #{u.email} (ID: #{u.id})"
    puts "Company ID: #{u.company_id}"
    puts "Legacy Role: #{u.role}"
    puts "Uses RBAC: #{u.uses_rbac?}"
    puts "Effective Admin: #{u.effective_admin?}"
    puts "=" * 60
    puts ""
    puts "Role Assignments:"
    u.user_role_assignments.includes(:role).each do |a|
      puts "  - #{a.role&.name} (#{a.role&.key}), company_id: #{a.company_id}, tier: #{a.tier}"
    end
    puts ""
    puts "Key Permissions:"
    %w[documents listings branding inventory crm].each do |resource|
      result = u.has_permission?(resource, 'read', 'all', u.company_id)
      status = result ? "YES" : "NO"
      puts "  #{resource}:read = #{status}"
    end
  end
end
