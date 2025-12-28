# frozen_string_literal: true

class AddQuickbooksSettingsToCompaniesAndLocations < ActiveRecord::Migration[8.0]
  def change
    # Add quickbooks_settings JSONB column if it doesn't exist
    unless column_exists?(:companies, :quickbooks_settings)
      add_column :companies, :quickbooks_settings, :jsonb, default: {}
    end
    
    unless column_exists?(:locations, :quickbooks_settings)
      add_column :locations, :quickbooks_settings, :jsonb, default: {}
    end
  end
end
