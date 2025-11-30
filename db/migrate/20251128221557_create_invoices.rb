class CreateInvoices < ActiveRecord::Migration[8.0]
  def change
    create_table :invoices do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, foreign_key: true
      t.references :contact, null: false, foreign_key: true
      t.references :listing, foreign_key: true
      t.references :deal, foreign_key: true
      
      t.string :invoice_number, null: false
      t.string :status, default: 'draft'
      
      t.date :invoice_date, null: false
      t.date :due_date
      
      t.decimal :subtotal, precision: 10, scale: 2, default: 0
      t.decimal :tax_rate, precision: 5, scale: 2, default: 0
      t.decimal :tax_amount, precision: 10, scale: 2, default: 0
      t.decimal :total, precision: 10, scale: 2, default: 0
      t.decimal :amount_paid, precision: 10, scale: 2, default: 0
      t.decimal :amount_due, precision: 10, scale: 2, default: 0
      
      t.text :notes
      t.text :terms
      t.text :footer_text
      
      t.string :payment_token
      t.datetime :sent_at
      t.datetime :viewed_at
      t.datetime :paid_at
      
      t.boolean :is_deleted, default: false
      
      t.timestamps
    end
    
    add_index :invoices, [:company_id, :invoice_number], unique: true
    add_index :invoices, :payment_token, unique: true
    add_index :invoices, :status
    add_index :invoices, :due_date
    
    create_table :invoice_items do |t|
      t.references :invoice, null: false, foreign_key: true
      
      t.string :item_type
      t.string :description, null: false
      t.decimal :quantity, precision: 10, scale: 2, default: 1
      t.decimal :rate, precision: 10, scale: 2, null: false
      t.decimal :amount, precision: 10, scale: 2, null: false
      
      t.references :listing, foreign_key: true
      t.integer :position, default: 0
      
      t.timestamps
    end
    
    add_index :invoice_items, [:invoice_id, :position]
  end
end
