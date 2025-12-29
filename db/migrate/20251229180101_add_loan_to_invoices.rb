# frozen_string_literal: true

class AddLoanToInvoices < ActiveRecord::Migration[8.0]
  def change
    add_column :invoices, :loan_id, :integer
    add_column :invoices, :loan_payment_number, :integer
    
    add_index :invoices, :loan_id
    add_index :invoices, [:loan_id, :loan_payment_number], name: 'index_invoices_on_loan_and_payment_number'
  end
end
