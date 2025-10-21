class AddCustomerNameAndSourceToDeals < ActiveRecord::Migration[8.0]
  def change
    # Add customer_name field for manual customer name entry
    add_column :deals, :customer_name, :string
    
    # Add source_id to track where the deal came from
    add_column :deals, :source_id, :integer
    
    # Add index for source queries
    add_index :deals, :source_id
    
    # Add foreign key to sources table
    add_foreign_key :deals, :sources, column: :source_id
  end
end
