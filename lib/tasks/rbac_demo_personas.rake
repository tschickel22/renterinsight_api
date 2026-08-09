# frozen_string_literal: true

# Demo personas, kept away from the roles real tenants are using.
#
# The shipped system roles (sales_rep, service_tech, ...) are shared: editing
# one to make a demo look right changes what every customer holding it can see.
# This clones them into company-scoped copies prefixed `demo_`, so a demo can be
# tuned freely and production is untouched.
#
#   bin/rails rbac:demo_personas COMPANY_ID=47
#   bin/rails rbac:demo_personas COMPANY_ID=47 ONLY=sales_rep,service_tech
#   bin/rails rbac:demo_personas COMPANY_ID=47 RESET=true   # rebuild from template
namespace :rbac do
  PERSONA_TEMPLATES = %w[sales_rep service_tech finance_staff crm_specialist inventory_manager].freeze

  desc 'Create company-scoped demo copies of the persona roles (COMPANY_ID required)'
  task demo_personas: :environment do
    company_id = ENV['COMPANY_ID']
    abort 'COMPANY_ID is required, e.g. bin/rails rbac:demo_personas COMPANY_ID=47' if company_id.blank?

    company = Company.find_by(id: company_id)
    abort "No company with id #{company_id}" unless company

    wanted = ENV['ONLY'].present? ? ENV['ONLY'].split(',').map(&:strip) : PERSONA_TEMPLATES
    reset = ENV['RESET'] == 'true'

    puts "Demo personas for #{company.name} (id #{company.id})"
    puts "Rebuilding from template (RESET=true)\n" if reset
    puts

    wanted.each do |template_key|
      template = Role.system_roles.find_by(key: template_key)
      unless template
        puts "  #{template_key.ljust(20)} SKIPPED, no such system role"
        next
      end

      demo_key = "demo_#{template_key}"
      role = Role.find_or_initialize_by(company_id: company.id, key: demo_key)
      created = role.new_record?

      role.assign_attributes(
        name: "Demo: #{template.name}",
        description: "Demo persona cloned from #{template.name}. Safe to edit; not shared with other companies.",
        tier: template.tier,
        color: template.color,
        active: true
      )
      role.save!

      role.role_permissions.destroy_all if reset && !created

      copied = 0
      template.role_permissions.includes(:resource, :action, :scope).find_each do |source|
        permission = RolePermission.find_or_initialize_by(
          role: role, resource_id: source.resource_id,
          action_id: source.action_id, scope_id: source.scope_id
        )
        next unless permission.new_record?

        permission.granted = source.granted
        permission.save!
        copied += 1
      end

      state = created ? 'created' : (reset ? 'rebuilt' : 'updated')
      puts "  #{demo_key.ljust(24)} #{state}, #{copied} permission(s) copied, " \
           "#{role.role_permissions.granted.count} granted total"
    end

    puts
    puts 'Assign one to a demo user:'
    puts "  u = User.find_by(email: 'someone@example.com')"
    puts "  r = Role.find_by(company_id: #{company.id}, key: 'demo_sales_rep')"
    puts "  u.user_role_assignments.destroy_all"
    puts "  u.user_role_assignments.create!(role: r, company_id: #{company.id}, tier: r.tier, " \
         'location: Location.find(<location_id>))   # location required for location-tier roles'
    puts
    puts 'These are company-scoped. Editing them cannot affect another tenant.'
  end
end
