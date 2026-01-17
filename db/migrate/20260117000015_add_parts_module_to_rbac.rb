# frozen_string_literal: true

class AddPartsModuleToRbac < ActiveRecord::Migration[8.0]
  def up
    # Get the 'all' scope
    all_scope = Scope.find_or_create_by!(key: 'all') { |s| s.name = 'All' }
    
    # Resources for Parts Module
    resources_to_create = [
      { key: 'parts', name: 'Parts', description: 'Manage parts catalog', category: 'operations' },
      { key: 'part_categories', name: 'Part Categories', description: 'Manage part categories', category: 'operations' },
      { key: 'suppliers', name: 'Suppliers', description: 'Manage suppliers', category: 'operations' },
      { key: 'bins', name: 'Warehouse Bins', description: 'Manage warehouse bins and locations', category: 'operations' }
    ]
    
    resources_to_create.each do |resource_attrs|
      # Create or find resource
      resource = Resource.find_or_create_by!(key: resource_attrs[:key]) do |r|
        r.name = resource_attrs[:name]
        r.description = resource_attrs[:description]
        r.category = resource_attrs[:category]
        r.active = true
      end
      
      puts "Created resource: #{resource.name}"
      
      # Create standard actions for CRUD resources
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
    
    puts "✅ Parts module RBAC permissions created successfully"
  end
  
  def down
    # Remove permissions and resources
    ['parts', 'part_categories', 'suppliers', 'bins'].each do |resource_key|
      resource = Resource.find_by(key: resource_key)
      if resource
        # Delete role permissions
        RolePermission.where(resource: resource).destroy_all
        # Delete resource
        resource.destroy
        puts "Removed resource: #{resource_key}"
      end
    end
  end
end
