# frozen_string_literal: true

# RBAC Migration Rake Tasks
#
# Usage:
#   bin/rails rbac:migrate:company[1]              # Migrate company ID 1
#   bin/rails rbac:migrate:test[1]                 # Test migration for company ID 1 (dry run)
#   bin/rails rbac:migrate:user[user_id]           # Migrate single user
#   bin/rails rbac:rollback:company[1]             # Rollback RBAC for company ID 1
#   bin/rails rbac:status                          # Show RBAC status for all companies
#   bin/rails rbac:seed                            # Seed RBAC system (resources, actions, roles)

namespace :rbac do
  desc 'Show RBAC status for all companies'
  task status: :environment do
    puts "\n=== RBAC System Status ==="
    puts "\nSystem Roles: #{Role.system_roles.count}"
    puts "Resources: #{Resource.count}"
    puts "Actions: #{Action.count}"
    puts "Scopes: #{Scope.count}"
    
    puts "\n=== Companies ==="
    Company.order(:id).each do |company|
      status = company.use_rbac_system ? '✅ ENABLED' : '❌ DISABLED'
      users_with_rbac = company.users.joins(:user_role_assignments).distinct.count
      total_users = company.users.count
      
      puts "\nCompany #{company.id}: #{company.name}"
      puts "  RBAC Status: #{status}"
      puts "  Users: #{total_users} total, #{users_with_rbac} with RBAC roles"
      puts "  Custom Roles: #{company.roles.where(is_system_role: false).count}"
    end
    puts "\n"
  end
  
  desc 'Seed RBAC system (resources, actions, scopes, roles)'
  task seed: :environment do
    puts "\n=== Seeding RBAC System ==="
    
    # Run the seed file
    load Rails.root.join('db/seeds/rbac_system_seed.rb')
    
    puts "\n✅ RBAC system seeded successfully"
    puts "Resources: #{Resource.count}"
    puts "Actions: #{Action.count}"
    puts "Scopes: #{Scope.count}"
    puts "System Roles: #{Role.system_roles.count}"
    puts "\n"
  end
  
  namespace :migrate do
    desc 'Test RBAC migration for a company (dry run)'
    task :test, [:company_id] => :environment do |t, args|
      company_id = args[:company_id] || ENV['COMPANY_ID']
      
      unless company_id
        puts "❌ Error: Company ID required"
        puts "Usage: bin/rails rbac:migrate:test[1]"
        exit 1
      end
      
      company = Company.find(company_id)
      service = RbacMigrationService.new(company)
      
      puts "\n=== RBAC Migration Test for #{company.name} ==="
      puts "\n🔍 Analyzing migration plan...\n"
      
      plan = service.test_migration
      
      puts "\nCompany: #{plan[:company][:name]} (ID: #{plan[:company][:id]})"
      puts "Current RBAC Status: #{plan[:company][:current_rbac_status] ? 'ENABLED' : 'DISABLED'}"
      
      puts "\n=== Migration Summary ==="
      puts "Total Users: #{plan[:summary][:total_users]}"
      
      puts "\nUsers by Legacy Role:"
      plan[:summary][:by_legacy_role].each do |role, count|
        puts "  #{role}: #{count}"
      end
      
      puts "\nTarget RBAC Roles:"
      plan[:summary][:by_target_role].each do |role, count|
        role_obj = Role.find_by(key: role)
        puts "  #{role_obj&.name || role}: #{count}"
      end
      
      puts "\n=== User Migration Details ==="
      plan[:users].each do |user_plan|
        puts "\nUser: #{user_plan[:name]} (#{user_plan[:email]})"
        puts "  Current Role: #{user_plan[:legacy_role] || 'none'}"
        puts "  Target RBAC Roles:"
        user_plan[:target_roles].each do |role|
          puts "    - #{role[:role_name]} (#{role[:tier]}) - #{role[:scope]}"
        end
      end
      
      puts "\n✅ Migration test completed (no changes made)"
      puts "To perform actual migration, run: bin/rails rbac:migrate:company[#{company_id}]"
      puts "\n"
    end
    
    desc 'Migrate a company to RBAC system'
    task :company, [:company_id] => :environment do |t, args|
      company_id = args[:company_id] || ENV['COMPANY_ID']
      
      unless company_id
        puts "❌ Error: Company ID required"
        puts "Usage: bin/rails rbac:migrate:company[1]"
        exit 1
      end
      
      company = Company.find(company_id)
      
      if company.use_rbac_system
        puts "⚠️  Company #{company.name} already using RBAC system"
        exit 0
      end
      
      puts "\n=== Migrating #{company.name} to RBAC ==="
      
      service = RbacMigrationService.new(company)
      
      if service.migrate!
        puts "\n✅ Migration completed successfully!"
        puts "\nMigration Log:"
        service.migration_log.each { |msg| puts "  #{msg}" }
        
        puts "\n=== Post-Migration Status ==="
        puts "RBAC Enabled: #{company.reload.use_rbac_system}"
        puts "Users Migrated: #{company.users.joins(:user_role_assignments).distinct.count}"
        puts "Total Role Assignments: #{UserRoleAssignment.where(company_id: company.id).count}"
      else
        puts "\n❌ Migration failed!"
        puts "\nErrors:"
        service.errors.each { |err| puts "  - #{err}" }
        exit 1
      end
      
      puts "\n"
    end
    
    desc 'Migrate a single user to RBAC'
    task :user, [:user_id] => :environment do |t, args|
      user_id = args[:user_id] || ENV['USER_ID']
      
      unless user_id
        puts "❌ Error: User ID required"
        puts "Usage: bin/rails rbac:migrate:user[123]"
        exit 1
      end
      
      user = User.find(user_id)
      company = user.company
      
      unless company.use_rbac_system
        puts "⚠️  Company #{company.name} is not using RBAC system"
        puts "Enable RBAC first: bin/rails rbac:migrate:company[#{company.id}]"
        exit 1
      end
      
      puts "\n=== Migrating User to RBAC ==="
      puts "User: #{user.name} (#{user.email})"
      puts "Company: #{company.name}"
      
      service = RbacMigrationService.new(company)
      
      if service.migrate_user!(user)
        puts "\n✅ User migrated successfully!"
        puts "\nMigration Log:"
        service.migration_log.each { |msg| puts "  #{msg}" }
        
        puts "\n=== User's RBAC Roles ==="
        user.reload.user_role_assignments.includes(:role).each do |assignment|
          puts "  - #{assignment.role.name} (#{assignment.tier})"
          puts "    Location: #{assignment.location_id}" if assignment.location_id
          puts "    Region: #{assignment.region_id}" if assignment.region_id
        end
      else
        puts "\n❌ User migration failed!"
        puts "\nErrors:"
        service.errors.each { |err| puts "  - #{err}" }
        exit 1
      end
      
      puts "\n"
    end
  end
  
  namespace :rollback do
    desc 'Rollback RBAC migration for a company'
    task :company, [:company_id] => :environment do |t, args|
      company_id = args[:company_id] || ENV['COMPANY_ID']
      
      unless company_id
        puts "❌ Error: Company ID required"
        puts "Usage: bin/rails rbac:rollback:company[1]"
        exit 1
      end
      
      company = Company.find(company_id)
      
      unless company.use_rbac_system
        puts "⚠️  Company #{company.name} is not using RBAC system"
        exit 0
      end
      
      puts "\n=== Rolling Back RBAC for #{company.name} ==="
      puts "\n⚠️  WARNING: This will:"
      puts "  - Remove all RBAC role assignments for company users"
      puts "  - Delete all custom company roles"
      puts "  - Disable RBAC system for company"
      puts "  - Users will revert to legacy role system"
      
      print "\nType 'yes' to confirm rollback: "
      confirmation = STDIN.gets.chomp
      
      unless confirmation.downcase == 'yes'
        puts "Rollback cancelled"
        exit 0
      end
      
      service = RbacMigrationService.new(company)
      
      if service.rollback!
        puts "\n✅ Rollback completed successfully!"
        puts "\nRollback Log:"
        service.migration_log.each { |msg| puts "  #{msg}" }
      else
        puts "\n❌ Rollback failed!"
        puts "\nErrors:"
        service.errors.each { |err| puts "  - #{err}" }
        exit 1
      end
      
      puts "\n"
    end
  end
end
