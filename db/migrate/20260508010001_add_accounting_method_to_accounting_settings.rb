# frozen_string_literal: true

class AddAccountingMethodToAccountingSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :accounting_settings, :accounting_method, :string, default: 'accrual', null: false
  end
end
