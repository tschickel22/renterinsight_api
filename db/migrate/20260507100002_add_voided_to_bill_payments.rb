# frozen_string_literal: true

class AddVoidedToBillPayments < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:bill_payments, :voided)
      add_column :bill_payments, :voided, :boolean, null: false, default: false
    end

    unless column_exists?(:bill_payments, :voided_at)
      add_column :bill_payments, :voided_at, :datetime
    end

    unless index_exists?(:bill_payments, [:bill_id, :voided])
      add_index :bill_payments, [:bill_id, :voided]
    end
  end
end
