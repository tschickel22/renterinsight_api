class AddAccountNumberToSuppliers < ActiveRecord::Migration[8.0]
  def change
    add_column :suppliers, :account_number, :string
  end
end
