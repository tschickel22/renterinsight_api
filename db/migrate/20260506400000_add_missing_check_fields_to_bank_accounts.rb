# frozen_string_literal: true

class AddMissingCheckFieldsToBankAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :bank_accounts, :check_company_phone, :string unless column_exists?(:bank_accounts, :check_company_phone)
    add_column :bank_accounts, :check_bank_city, :string unless column_exists?(:bank_accounts, :check_bank_city)
    add_column :bank_accounts, :check_bank_state, :string unless column_exists?(:bank_accounts, :check_bank_state)
    add_column :bank_accounts, :check_aba_fractional_number, :string unless column_exists?(:bank_accounts, :check_aba_fractional_number)
    add_column :bank_accounts, :check_signature_heading, :string unless column_exists?(:bank_accounts, :check_signature_heading)
  end
end
