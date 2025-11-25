# frozen_string_literal: true

class AddLoanSettingsToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :loan_settings, :jsonb, default: {}, null: false
    add_index :companies, :loan_settings, using: :gin
  end
end
