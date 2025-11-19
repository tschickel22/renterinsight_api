# frozen_string_literal: true

class AddColorToRoles < ActiveRecord::Migration[7.0]
  def change
    add_column :roles, :color, :string
    
    # Update existing system roles with their designated colors
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE roles SET color = '#ef4444' WHERE key = 'company_admin';
          UPDATE roles SET color = '#f97316' WHERE key = 'company_manager';
          UPDATE roles SET color = '#3b82f6' WHERE key = 'company_staff';
          UPDATE roles SET color = '#6b7280' WHERE key = 'company_read_only';
          UPDATE roles SET color = '#8b5cf6' WHERE key = 'location_admin';
          UPDATE roles SET color = '#06b6d4' WHERE key = 'location_manager';
          UPDATE roles SET color = '#10b981' WHERE key = 'location_staff';
        SQL
      end
    end
  end
end
