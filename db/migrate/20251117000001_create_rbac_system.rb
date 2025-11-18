# frozen_string_literal: true

# RBAC (Role-Based Access Control) System Migration
# 
# This migration creates the foundation for an enterprise-grade configurable
# permission system that allows companies to define custom roles and permissions.
# 
# Architecture:
# - Resources: What can be accessed (inventory, users, locations, etc.)
# - Actions: What can be done (create, read, update, delete, etc.)
# - Scopes: Where access applies (all, assigned_regions, assigned_locations, own)
# - Roles: Configurable role definitions (company-level customization)
# - RolePermissions: Permission matrix (role → resource → action → scope)
# - UserRoleAssignments: User → Role mappings with tier context
#
# Non-Breaking Change: Existing User.role and UserLocation.location_role remain intact.
# Companies opt-in via use_rbac_system flag.

class CreateRbacSystem < ActiveRecord::Migration[8.0]
  def change
    # System Resources (Platform-defined)
    create_table :resources do |t|
      t.string :key, null: false, limit: 100, index: { unique: true }
      t.string :name, null: false
      t.text :description
      t.string :category, limit: 50  # 'core', 'operations', 'admin'
      t.boolean :active, default: true, null: false
      
      t.timestamps
    end

    add_index :resources, :category
    add_index :resources, :active

    # System Actions (Platform-defined)
    create_table :actions do |t|
      t.string :key, null: false, limit: 100, index: { unique: true }
      t.string :name, null: false
      t.text :description
      
      t.timestamps
    end

    # System Scopes (Platform-defined)
    create_table :scopes do |t|
      t.string :key, null: false, limit: 100, index: { unique: true }
      t.string :name, null: false
      t.text :description
      
      t.timestamps
    end

    # Roles (Company-configurable with platform defaults)
    create_table :roles do |t|
      t.bigint :company_id, index: true
      t.string :tier, null: false, limit: 50  # 'company', 'region', 'location'
      t.string :key, null: false, limit: 100
      t.string :name, null: false
      t.text :description
      t.boolean :is_system_role, default: false, null: false
      t.boolean :active, default: true, null: false
      
      t.timestamps
    end

    add_index :roles, [:company_id, :tier, :key], unique: true, name: 'index_roles_unique_per_company'
    add_index :roles, :tier
    add_index :roles, :is_system_role
    add_index :roles, :active
    add_foreign_key :roles, :companies, on_delete: :cascade

    # Role Permissions (Configurable permission assignments)
    create_table :role_permissions do |t|
      t.bigint :role_id, null: false, index: true
      t.bigint :resource_id, null: false, index: true
      t.bigint :action_id, null: false, index: true
      t.bigint :scope_id, null: false, index: true
      t.boolean :granted, default: true, null: false
      
      t.timestamps
    end

    add_index :role_permissions, [:role_id, :resource_id, :action_id, :scope_id], 
              unique: true, name: 'index_role_permissions_unique'
    add_index :role_permissions, [:role_id, :granted], name: 'index_role_permissions_granted'
    
    add_foreign_key :role_permissions, :roles, on_delete: :cascade
    add_foreign_key :role_permissions, :resources, on_delete: :cascade
    add_foreign_key :role_permissions, :actions, on_delete: :cascade
    add_foreign_key :role_permissions, :scopes, on_delete: :cascade

    # User Role Assignments (Replaces old company_role, region_role, location_role)
    create_table :user_role_assignments do |t|
      t.bigint :user_id, null: false, index: true
      t.bigint :role_id, null: false, index: true
      
      # Scope of role assignment
      t.string :tier, null: false, limit: 50  # 'company', 'region', 'location'
      t.bigint :region_id, index: true
      t.bigint :location_id, index: true
      
      t.bigint :assigned_by_id
      t.datetime :assigned_at, default: -> { 'CURRENT_TIMESTAMP' }
      t.datetime :expires_at
      
      t.timestamps
    end

    add_index :user_role_assignments, [:user_id, :role_id, :tier, :region_id, :location_id], 
              unique: true, name: 'index_user_role_assignments_unique'
    add_index :user_role_assignments, :tier
    add_index :user_role_assignments, :expires_at
    
    add_foreign_key :user_role_assignments, :users, on_delete: :cascade
    add_foreign_key :user_role_assignments, :roles, on_delete: :cascade
    add_foreign_key :user_role_assignments, :users, column: :assigned_by_id, on_delete: :nullify

    # Add RBAC opt-in flag to companies
    add_column :companies, :use_rbac_system, :boolean, default: false, null: false
    add_index :companies, :use_rbac_system

    # Add check constraint for tier assignment validation
    execute <<-SQL
      ALTER TABLE user_role_assignments
      ADD CONSTRAINT check_tier_assignment CHECK (
        (tier = 'company' AND region_id IS NULL AND location_id IS NULL) OR
        (tier = 'region' AND region_id IS NOT NULL AND location_id IS NULL) OR
        (tier = 'location' AND location_id IS NOT NULL)
      );
    SQL
  end
end
