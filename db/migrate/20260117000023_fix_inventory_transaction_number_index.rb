# frozen_string_literal: true

class FixInventoryTransactionNumberIndex < ActiveRecord::Migration[7.2]
  def up
    # Remove the old unique index on transaction_number alone
    remove_index :inventory_transactions, 
                 name: 'index_inventory_transactions_on_transaction_number',
                 if_exists: true
    
    # Add compound unique index on [company_id, transaction_number]
    # This allows TXN-00001 for each company, not globally
    add_index :inventory_transactions, 
              [:company_id, :transaction_number],
              unique: true,
              name: 'index_inventory_transactions_on_company_and_number'
  end

  def down
    # Reverse the migration
    remove_index :inventory_transactions, 
                 name: 'index_inventory_transactions_on_company_and_number',
                 if_exists: true
    
    add_index :inventory_transactions, 
              :transaction_number,
              unique: true,
              name: 'index_inventory_transactions_on_transaction_number'
  end
end
