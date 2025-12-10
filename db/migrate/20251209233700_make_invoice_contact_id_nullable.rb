# frozen_string_literal: true

class MakeInvoiceContactIdNullable < ActiveRecord::Migration[8.0]
  def change
    change_column_null :invoices, :contact_id, true
  end
end
