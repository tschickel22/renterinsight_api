# frozen_string_literal: true

# Add Permission UI Type to Resources
# 
# This migration adds metadata to resources to indicate which permission UI to use:
# - 'standard_crud': Standard CRUD permission matrix (Create, Read, Update, Delete, etc.)
# - 'specialized': Custom permission groups with domain-specific actions
# 
# Also adds permission_groups JSONB field to store group configurations for specialized UIs.

class AddPermissionUiTypeToResources < ActiveRecord::Migration[8.0]
  def change
    add_column :resources, :permission_ui_type, :string, default: 'standard_crud', null: false
    add_column :resources, :permission_groups, :jsonb, default: {}, null: false
    
    add_index :resources, :permission_ui_type
    
    reversible do |dir|
      dir.up do
        # Update calendar resource to use specialized UI
        execute <<-SQL
          UPDATE resources 
          SET permission_ui_type = 'specialized',
              permission_groups = '{
                "personal": {
                  "name": "Personal Calendar",
                  "description": "Access to personal calendar and activities",
                  "permissions": [
                    {"action": "view_own", "scope": "own", "label": "View own calendar and activities"}
                  ]
                },
                "team": {
                  "name": "Team Collaboration",
                  "description": "View and manage team calendars",
                  "permissions": [
                    {"action": "view_team", "scope": "assigned_locations", "label": "View team calendars at assigned locations"},
                    {"action": "view_all", "scope": "all", "label": "View all company calendars"}
                  ]
                },
                "service": {
                  "name": "Service Tickets",
                  "description": "View service tickets in calendar",
                  "permissions": [
                    {"action": "view_service_all", "scope": "assigned_locations", "label": "View all service tickets in calendar view"},
                    {"action": "view_service_unassigned", "scope": "assigned_locations", "label": "View unassigned service tickets"}
                  ]
                },
                "management": {
                  "name": "Schedule Management",
                  "description": "Manage and reschedule calendar items",
                  "permissions": [
                    {"action": "manage_schedule", "scope": "all", "label": "Reschedule activities and manage calendar items"}
                  ]
                }
              }'::jsonb
          WHERE key = 'calendar'
        SQL
      end
    end
  end
end
