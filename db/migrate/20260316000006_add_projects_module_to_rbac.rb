# frozen_string_literal: true

class AddProjectsModuleToRbac < ActiveRecord::Migration[8.0]
  def up
    # Get the 'all' scope
    all_scope = Scope.find_or_create_by!(key: 'all') { |s| s.name = 'All' }

    # Resources for Projects Module
    resources_to_create = [
      { key: 'projects', name: 'Projects', description: 'Manage project progress tracking', category: 'operations', position: 106 },
      { key: 'project_templates', name: 'Project Templates', description: 'Manage reusable project phase templates', category: 'operations', position: 107 }
    ]

    resources_to_create.each do |resource_attrs|
      position = resource_attrs.delete(:position)

      resource = Resource.find_or_create_by!(key: resource_attrs[:key]) do |r|
        r.name = resource_attrs[:name]
        r.description = resource_attrs[:description]
        r.category = resource_attrs[:category]
        r.active = true
        r.position = position
      end

      # Update position if resource already existed
      resource.update_column(:position, position) if resource.position != position

      puts "Created resource: #{resource.name} (position: #{position})"

      # Create standard CRUD actions
      actions = {
        create: Action.find_or_create_by!(key: 'create') { |a| a.name = 'Create' },
        read: Action.find_or_create_by!(key: 'read') { |a| a.name = 'Read' },
        update: Action.find_or_create_by!(key: 'update') { |a| a.name = 'Update' },
        delete: Action.find_or_create_by!(key: 'delete') { |a| a.name = 'Delete' }
      }

      # Grant to Platform Admin and Company Admin roles by default
      ['platform_admin', 'company_admin'].each do |role_key|
        role = Role.find_by(key: role_key)
        next unless role

        actions.each do |_action_key, action|
          RolePermission.find_or_create_by!(
            role: role,
            resource: resource,
            action: action,
            scope: all_scope
          ) do |rp|
            rp.granted = true
          end
        end
      end
    end

    puts "✅ Projects module RBAC permissions created successfully"
  end

  def down
    ['projects', 'project_templates'].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      if resource
        RolePermission.where(resource: resource).destroy_all
        resource.destroy
        puts "Removed resource: #{resource_key}"
      end
    end
  end
end
