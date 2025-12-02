class AddCurrentPeriodPaidToLoans < ActiveRecord::Migration[7.0]
  def change
    add_column :loans, :current_period_paid, :decimal, precision: 10, scale: 2, default: 0.0
    add_column :loans, :current_period_late_fees, :decimal, precision: 10, scale: 2, default: 0.0
  end
end
