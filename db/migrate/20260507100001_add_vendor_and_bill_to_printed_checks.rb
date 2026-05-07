# frozen_string_literal: true

class AddVendorAndBillToPrintedChecks < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:printed_checks, :vendor_id)
      add_reference :printed_checks, :vendor, null: true, foreign_key: true
    end

    unless column_exists?(:printed_checks, :bill_id)
      add_reference :printed_checks, :bill, null: true, foreign_key: true
    end

    unless column_exists?(:printed_checks, :bill_payment_id)
      add_reference :printed_checks, :bill_payment, null: true, foreign_key: true
    end

    # [:company_id, :status] already exists from the original create migration —
    # skip if present.
    unless index_exists?(:printed_checks, [:company_id, :status])
      add_index :printed_checks, [:company_id, :status]
    end
  end
end
