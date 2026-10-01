# frozen_string_literal: true

# Who may connect Claude or ChatGPT (backlog E53) is now a permission, not just
# the company's add-on. Read: may connect, and the AI reads with the person's
# own permissions. Update: may also let the AI make changes. Create and delete
# mean nothing for this resource.
#
# Granted to the company_admin and platform_admin roles only, so every other
# role starts without it and a dealer opts reps in deliberately. Admins also
# pass through the usual admin bypass, so this grant mostly makes the roles
# editor show the truth.
class AddAiConnectorToRbac < ActiveRecord::Migration[8.0]
  def up
    resource = Resource.find_or_create_by!(key: 'ai_connector') do |r|
      r.name = 'AI Connector (Claude, ChatGPT)'
      r.description = 'Read: connect Claude or ChatGPT, which then sees only what this role can see. ' \
                      'Update: also let it make changes. Create and Delete do nothing here.'
      r.category = 'admin'
      r.active = true
      r.position = 12
    end

    all_scope = Scope.find_or_create_by!(key: 'all') { |s| s.name = 'All' }
    actions = %w[read update].map { |key| Action.find_or_create_by!(key: key) { |a| a.name = key.capitalize } }

    Role.where(key: %w[company_admin platform_admin]).find_each do |role|
      actions.each do |action|
        RolePermission.find_or_create_by!(role: role, resource: resource, action: action, scope: all_scope) do |rp|
          rp.granted = true
        end
      end
    end
  end

  def down
    resource = Resource.find_by(key: 'ai_connector')
    return unless resource

    RolePermission.where(resource: resource).delete_all
    resource.destroy
  end
end
