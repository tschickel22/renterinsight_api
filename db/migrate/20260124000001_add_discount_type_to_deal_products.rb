class AddDiscountTypeToDealProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :deal_products, :discount_type, :string, default: 'fixed', null: false
    
    # Add index for faster queries on discount_type
    add_index :deal_products, :discount_type
  end
end
