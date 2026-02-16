# frozen_string_literal: true

class AddModuleConfigAndWebsiteAccessLevel < ActiveRecord::Migration[8.0]
  def change
    # Add config JSONB to subscription_plan_modules
    # Stores per-module configuration like { "website_access_level": 3 }
    unless column_exists?(:subscription_plan_modules, :config)
      add_column :subscription_plan_modules, :config, :jsonb, default: {}
    end

    # Add config JSONB to tenant_module_overrides
    # Platform admin can override config per-company
    unless column_exists?(:tenant_module_overrides, :config)
      add_column :tenant_module_overrides, :config, :jsonb, default: {}
    end

    # Add client_access_level to websites (per-site override)
    # nil = use company/plan default, 0=none, 1=view_only, 2=content_editor, 3=full_editor
    unless column_exists?(:websites, :client_access_level)
      add_column :websites, :client_access_level, :integer, default: nil
    end
  end
end
