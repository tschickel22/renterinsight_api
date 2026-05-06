# frozen_string_literal: true

class MakeBankAccountFieldsOptional < ActiveRecord::Migration[8.0]
  def change
    change_column_null :bank_accounts, :location_id, true
    change_column_null :bank_accounts, :routing_number, true
    change_column_null :bank_accounts, :account_number, true
  end
end
