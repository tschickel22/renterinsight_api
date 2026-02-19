# frozen_string_literal: true

class AddCustomFieldValuesToAccountsAndContacts < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:accounts, :custom_field_values)
      add_column :accounts, :custom_field_values, :jsonb, default: {}, null: false
    end

    unless column_exists?(:contacts, :custom_field_values)
      add_column :contacts, :custom_field_values, :jsonb, default: {}, null: false
    end
  end
end
