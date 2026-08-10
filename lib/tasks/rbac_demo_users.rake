# frozen_string_literal: true

# One login per persona, so a demo is a logout and a login rather than a trip
# through the impersonation machinery.
#
# Creates (or updates) a user for each demo_* role that rbac:demo_personas made,
# assigns the role, and attaches a location when the role's tier needs one.
# Idempotent: re-running re-points the same users at the same roles.
#
# The password is never chosen here or committed. Supply it:
#
#   bin/rails rbac:demo_users COMPANY_ID=5 PASSWORD='...'
#   bin/rails rbac:demo_users COMPANY_ID=5 PASSWORD='...' LOCATION_ID=12
#   bin/rails rbac:demo_users COMPANY_ID=5 PASSWORD='...' DOMAIN=dealertide.com
namespace :rbac do
  desc 'Create one demo login per demo_* role (COMPANY_ID and PASSWORD required)'
  task demo_users: :environment do
    company_id = ENV['COMPANY_ID']
    password   = ENV['PASSWORD']

    abort 'COMPANY_ID is required.' if company_id.blank?
    abort 'PASSWORD is required. Choose one; it is never defaulted or stored in the repo.' if password.blank?

    company = Company.find_by(id: company_id)
    abort "No company with id #{company_id}" unless company

    demo_roles = Role.where(company_id: company.id).where('key LIKE ?', 'demo\_%').order(:key)
    if demo_roles.empty?
      abort "No demo_* roles on company #{company.id}. Run rbac:demo_personas COMPANY_ID=#{company.id} first."
    end

    location = if ENV['LOCATION_ID'].present?
                 company.locations.find_by(id: ENV['LOCATION_ID'])
               else
                 company.locations.order(:id).first
               end
    abort 'No location found. Pass LOCATION_ID=<id>.' if location.nil?

    domain = ENV.fetch('DOMAIN', 'dealertide.com')

    puts "Demo logins for #{company.name} (id #{company.id}), location #{location.name}"
    puts

    demo_roles.each do |role|
      persona = role.key.sub('demo_', '')
      email = "t+demo.#{persona.tr('_', '.')}@#{domain}"

      user = company.users.find_or_initialize_by(email: email)
      created = user.new_record?
      user.assign_attributes(
        first_name: persona.split('_').map(&:capitalize).join(' '),
        last_name: 'Demo',
        role: 'user',
        status: 'active',
        password: password,
        password_confirmation: password
      )
      user.save!

      # One role per demo user, so the persona is unambiguous.
      user.user_role_assignments.destroy_all
      user.user_role_assignments.create!(
        role: role,
        company_id: company.id,
        tier: role.tier,
        location: (role.tier == 'location' ? location : nil)
      )

      granted = role.role_permissions.granted.count
      puts format('  %-42s %-22s %s, %d permission(s)',
                  email, role.key, created ? 'created' : 'updated', granted)
    end

    # Permission answers are memoised for an hour and assignments do not sweep
    # them, so a re-pointed user would otherwise keep the old persona's menu.
    Role.clear_permission_caches!

    puts
    puts 'Log in as any of these to see that persona. Caches cleared for this'
    puts 'process; restart the service if more than one instance is running.'
  end
end
