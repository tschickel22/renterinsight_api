# frozen_string_literal: true

class AddPartialPaymentSupportToCommissionPayments < ActiveRecord::Migration[7.1]
  def change
    # Add fields to support partial payments
    add_column :commission_payments, :amount_paid, :decimal, precision: 10, scale: 2
    add_column :commission_payments, :remaining_balance, :decimal, precision: 10, scale: 2
    add_column :commission_payments, :paid_date, :date
    
    # Backfill existing paid records
    # For payments already marked as 'paid', set amount_paid = amount and remaining_balance = 0
    reversible do |dir|
      dir.up do
        # Update existing paid payments
        execute <<-SQL
          UPDATE commission_payments
          SET amount_paid = amount,
              remaining_balance = 0,
              paid_date = DATE(paid_at)
          WHERE status = 'paid' AND paid_at IS NOT NULL
        SQL
        
        # Update existing approved payments (not yet paid)
        execute <<-SQL
          UPDATE commission_payments
          SET amount_paid = NULL,
              remaining_balance = amount,
              paid_date = NULL
          WHERE status = 'approved'
        SQL
        
        # Update pending payments
        execute <<-SQL
          UPDATE commission_payments
          SET amount_paid = NULL,
              remaining_balance = amount,
              paid_date = NULL
          WHERE status = 'pending'
        SQL
      end
    end
  end
end
