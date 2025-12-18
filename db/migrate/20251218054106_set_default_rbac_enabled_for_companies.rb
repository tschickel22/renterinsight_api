# frozen_string_literal: true

class SetDefaultRbacEnabledForCompanies < ActiveRecord::Migration[8.0]
  def up
    # Set default value for use_rbac_system column to true for new companies
    change_column_default :companies, :use_rbac_system, from: nil, to: true
    
    # Enable RBAC for all existing companies (safe to run multiple times)
    Company.where(use_rbac_system: [false, nil]).update_all(use_rbac_system: true)
    
    puts "✅ Set use_rbac_system default to true"
    puts "✅ Enabled RBAC for #{Company.where(use_rbac_system: true).count} companies"
  end

  def down
    # Revert default value
    change_column_default :companies, :use_rbac_system, from: true, to: nil
  end
end
