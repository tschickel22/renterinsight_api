class AddFinancingFieldsToDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :deals, :payment_type, :string
    add_column :deals, :lender_name, :string
    add_column :deals, :financed_amount, :decimal, precision: 12, scale: 2
    add_column :deals, :down_payment_due_date, :date
    add_column :deals, :deal_invoice_id, :integer

    add_index :deals, :deal_invoice_id
    add_index :deals, :payment_type
  end
end
