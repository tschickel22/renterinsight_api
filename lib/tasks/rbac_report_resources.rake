# frozen_string_literal: true

# Give every role that can already open the reports the new keys those reports
# moved to.
#
# Four reports were regrouped by audience rather than by the page they sit on:
#
#   Deal Profitability      financial_reports -> sales_reports
#   Salesperson GP Pipeline deals             -> sales_reports
#   Inventory Stock List    deals             -> inventory_reports
#   Floor Plan              financial_reports -> inventory_reports
#
# Reassigning a key silently removes access unless the roles that hold the old
# one receive the new one. On production that is 33 users across five roles, so
# this is not optional and it must include company-scoped roles: one tenant has
# its own copy of a sales role, and skipping it would cost those users two
# reports.
#
# Purely additive. It grants and never revokes, so the old keys keep working
# through a release and the change can be rolled forward without a flag day.
#
#   bin/rails rbac:migrate_report_resources              # dry run
#   bin/rails rbac:migrate_report_resources CONFIRM=true # apply
namespace :rbac do
  SOURCE_REPORT_KEYS = %w[financial_reports deals].freeze
  NEW_REPORT_KEYS = %w[sales_reports inventory_reports].freeze

  desc 'Grant the new report resources to roles that already hold the old ones (dry run unless CONFIRM=true)'
  task migrate_report_resources: :environment do
    confirm = ENV['CONFIRM'] == 'true'

    Resource.seed_defaults
    new_resources = Resource.where(key: NEW_REPORT_KEYS).to_a
    if new_resources.size != NEW_REPORT_KEYS.size
      abort "Expected #{NEW_REPORT_KEYS.inspect} to exist after seeding, found #{new_resources.map(&:key).inspect}"
    end

    read = Action.find_by!(key: 'read')
    all_scope = Scope.find_by!(key: 'all')
    source_ids = Resource.where(key: SOURCE_REPORT_KEYS).pluck(:id)

    # Any role that can read a source key today, system or tenant-owned.
    eligible = Role.where(active: true).select do |role|
      RolePermission.where(role: role, resource_id: source_ids, action: read, granted: true).exists?
    end

    planned = eligible.flat_map do |role|
      new_resources.filter_map do |resource|
        existing = RolePermission.find_by(role: role, resource: resource, action: read, scope: all_scope)
        next if existing&.granted?

        { role: role, resource: resource, existing: existing }
      end
    end

    puts confirm ? 'Granting the new report resources:' : 'DRY RUN. Would grant:'
    puts

    if planned.empty?
      puts '  Nothing to do. Every eligible role already holds both keys.'
      next
    end

    planned.group_by { |p| p[:role] }.sort_by { |role, _| role.key }.each do |role, rows|
      users = UserRoleAssignment.where(role_id: role.id).distinct.count(:user_id)
      scope_label = role.company_id ? "company #{role.company_id}" : 'system'
      puts "  #{role.key.ljust(34)} #{scope_label.ljust(12)} #{users} user(s)  <- #{rows.map { |r| r[:resource].key }.join(', ')}"
    end

    puts
    puts "#{planned.size} grant(s) across #{planned.map { |p| p[:role].id }.uniq.size} role(s)."

    unless confirm
      puts
      puts 'Re-run with CONFIRM=true to apply.'
      next
    end

    planned.each do |row|
      permission = row[:existing] || RolePermission.new(
        role: row[:role], resource: row[:resource], action: read, scope: all_scope
      )
      permission.granted = true
      permission.save!
    end

    # These writes go through the model, so the after_save hook clears the
    # cached answers. Sweeping anyway costs nothing and covers the case where a
    # future edit here switches to update_all.
    Role.clear_permission_caches!

    puts
    puts '✅ Granted. Nothing was revoked; the old keys still work.'
    puts '   Restart the service if more than one instance is running.'
  end
end
