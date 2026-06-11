# frozen_string_literal: true

# Factory-installed A/C line from the manufacturer invoice (Max Advance). When present,
# the lender DELETES this cost from the net before markup (so it isn't marked up at
# 145-150%) and the calculator implicitly adds the lender's A/C ALLOWANCE in line F —
# matching the 21st worksheet where A/C appears in both DELETIONS and ADDS.
class AddAcFromInvoiceToVehicleInvoices < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicle_invoices, :ac_from_invoice, :decimal, precision: 15, scale: 2
  end
end
