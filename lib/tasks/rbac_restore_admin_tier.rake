# frozen_string_literal: true

# Undo the narrowing that an earlier version of rbac:reconcile applied to the
# shipped templates.
#
# That reconcile revoked the admin-tier resources from every non-admin system
# role before we pulled production and saw the cost: company_manager loses user
# and location management, sales reps lose the activity log. It is additive now
# and narrows only the demo copies, but any database where the old version ran
# is left with templates that no longer match production. Staging is one, which
# makes it a poor place to predict production behaviour.
#
# Only touches rows that are currently OFF for the admin-tier resources on
# non-admin SYSTEM roles. Company-scoped roles were never narrowed, and the
# templates are seeded exclusively with granted=true rows, so an off row there
# is one this tool put off.
#
#   bin/rails rbac:restore_admin_tier                 # dry run, prints the diff
#   bin/rails rbac:restore_admin_tier CONFIRM=true    # apply
namespace :rbac do
  desc 'Restore admin-tier grants on shipped templates narrowed by the old reconcile (dry run unless CONFIRM=true)'
  task restore_admin_tier: :environment do
    confirm = ENV['CONFIRM'] == 'true'

    roles = Role.system_roles.where(active: true).where.not(key: Role::ADMIN_ROLE_KEYS)
    resource_ids = Resource.where(key: Role::ADMIN_TIER_RESOURCES).pluck(:id)

    if resource_ids.empty?
      puts 'No admin-tier resources found. Run Resource.seed_defaults first.'
      next
    end

    off = RolePermission
          .where(role: roles, resource_id: resource_ids, granted: false)
          .includes(:role, :resource, :action)

    if off.empty?
      puts '✅ Nothing to restore. Templates already match an un-narrowed database.'
      puts
      print_template_fingerprint
      next
    end

    puts confirm ? 'Restoring admin-tier grants:' : 'DRY RUN. Would restore:'
    puts

    off.group_by { |rp| rp.role.key }.sort.each do |role_key, rows|
      users = UserRoleAssignment.where(role_id: rows.first.role_id).distinct.count(:user_id)
      puts "  #{role_key} (#{users} user(s))"
      rows.group_by { |rp| rp.resource.key }.sort.each do |resource_key, group|
        puts "    #{resource_key.ljust(20)} #{group.map { |rp| rp.action.key }.sort.join(', ')}"
      end
    end

    puts
    puts "#{off.size} permission row(s) across #{off.map(&:role_id).uniq.size} role(s)."

    unless confirm
      puts
      puts 'Re-run with CONFIRM=true to apply.'
      next
    end

    # update_all skips the callback that clears cached permission answers, so
    # sweep afterwards or every process keeps serving the old denial for an hour.
    RolePermission.where(id: off.map(&:id)).update_all(granted: true)
    Role.clear_permission_caches!

    puts
    puts '✅ Restored. Permission caches cleared for this process.'
    puts '   Restart the service if more than one instance is running: the'
    puts '   default cache store is per-container.'
    puts
    print_template_fingerprint
  end

  # Comparable summary of the shipped templates. Run this on staging and on
  # production and diff the two: matching output means staging predicts
  # production again, which is the whole point of restoring.
  def self.print_template_fingerprint
    puts 'Template fingerprint (compare against production):'
    Role.system_roles.where(active: true).order(:key).each do |role|
      tier = role.role_permissions.granted.joins(:resource)
                 .where(resources: { key: Role::ADMIN_TIER_RESOURCES })
                 .distinct.pluck('resources.key').sort
      puts format('  %-18s granted=%-5d admin_tier=%s',
                  role.key, role.role_permissions.granted.count, tier.any? ? tier.join(',') : '-')
    end
  end
end
