# frozen_string_literal: true

class AddActionTypeToBankRules < ActiveRecord::Migration[8.0]
  def change
    add_column :bank_rules, :action_type, :string, default: 'categorize', null: false
    add_column :bank_rules, :exclude_reason, :string

    # Make assign_account_id nullable for exclude rules
    change_column_null :bank_rules, :assign_account_id, true
  end
end
