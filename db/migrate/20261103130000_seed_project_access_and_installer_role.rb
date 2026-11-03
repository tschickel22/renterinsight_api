# frozen_string_literal: true

# Tom, 2026-11-03: project management goes to every built-in role, and install
# companies get an Installer role.
#
# The bundle is the one production already gave Sales Representative, Company
# Manager and Finance Staff. Read-Only gets read only. Roles a company made for
# itself are theirs and are left alone.
class SeedProjectAccessAndInstallerRole < ActiveRecord::Migration[8.0]
  BUNDLE = %w[read create update delete assign approve manage export import view_pii].freeze

  def up
    resource = Resource.find_by(key: 'projects')
    if resource
      scope = Scope.find_or_create_by!(key: 'all') { |s| s.name = 'All' }
      Role.where(is_system_role: true, company_id: nil, active: true).find_each do |role|
        (role.key == 'company_read_only' ? %w[read] : BUNDLE).each do |action_key|
          action = Action.find_or_create_by!(key: action_key) { |a| a.name = action_key.humanize }
          grant = RolePermission.find_or_initialize_by(role: role, resource: resource, action: action, scope: scope)
          grant.update!(granted: true)
        end
      end
    end

    Company.where(industry: 'installer').find_each { |company| InstallerRoleSeeder.call(company) }
  end

  # Nothing to undo safely: some of these grants already existed before this ran,
  # and taking them away could lock people out of projects.
  def down; end
end
