class AddPayableToPayments < ActiveRecord::Migration[8.0]
  def change
    add_column :payments, :payable_type, :string
    add_column :payments, :payable_id, :bigint
    add_index :payments, [:payable_type, :payable_id]
  end
end
