# frozen_string_literal: true

class AddSmsProvisioningModeToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :sms_provisioning_mode, :string, default: 'platform', null: false
    add_index :companies, :sms_provisioning_mode
  end
end
