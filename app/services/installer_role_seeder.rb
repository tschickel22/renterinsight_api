# frozen_string_literal: true

# Every install company starts with an Installer role: runs the jobs, sees the
# customer details on them (Tom, 2026-10-06, E68), and stays out of the money,
# users and settings. It belongs to the company, not the platform, so ordinary
# dealers never see it in their role pickers and each installer can edit its own.
class InstallerRoleSeeder
  KEY = 'installer'
  NAME = 'Installer'
  DESCRIPTION = 'Runs install jobs: projects, tasks, calendar and service, with customer details. No accounting, users or settings.'

  PERMISSIONS = {
    'projects' => %w[read create update assign manage_schedule view_pii],
    'project_templates' => %w[read],
    'contractors' => %w[read assign],
    'tasks' => %w[read create update],
    'calendar' => %w[read],
    'crm' => %w[read],
    'service' => %w[read update],
    'documents' => %w[read create],
    'dashboard' => %w[read],
    'notifications' => %w[read]
  }.freeze

  # Safe to run again: an installer's own edits to the role are left alone.
  def self.call(company)
    existing = Role.find_by(company_id: company.id, tier: 'company', key: KEY)
    return existing if existing

    scope = Scope.find_or_create_by!(key: 'all') { |s| s.name = 'All' }
    Role.transaction do
      role = Role.create!(company_id: company.id, tier: 'company', key: KEY, name: NAME, description: DESCRIPTION,
                          is_system_role: false, active: true)
      PERMISSIONS.each do |resource_key, action_keys|
        resource = Resource.find_by(key: resource_key)
        next unless resource

        action_keys.each do |action_key|
          action = Action.find_or_create_by!(key: action_key) { |a| a.name = action_key.humanize }
          RolePermission.create!(role: role, resource: resource, action: action, scope: scope, granted: true)
        end
      end
      role
    end
  end
end
