# frozen_string_literal: true

class CreateServiceTickets < ActiveRecord::Migration[7.2]
  def change
    # Only create table if it doesn't exist
    unless table_exists?(:service_tickets)
      create_table :service_tickets do |t|
        t.references :company, null: false, foreign_key: true
        t.references :account, null: true, foreign_key: true
        t.references :contact, null: true, foreign_key: true
        t.references :vehicle, null: true, foreign_key: true
        t.string :customer_id, null: true
        t.string :customer_type, null: true
        
        t.string :title, null: false
        t.text :description
        t.string :priority, null: false, default: 'medium'
        t.string :status, null: false, default: 'open'
        t.string :assigned_to
        
        t.date :scheduled_date
        t.date :completed_date
        
        t.text :parts
        t.text :labor
        t.text :notes
        t.text :custom_fields
        
        t.datetime :deleted_at
        t.timestamps
      end
    end
    
    # Add indexes only if they don't exist
    add_index :service_tickets, :status unless index_exists?(:service_tickets, :status)
    add_index :service_tickets, :priority unless index_exists?(:service_tickets, :priority)
    add_index :service_tickets, :assigned_to unless index_exists?(:service_tickets, :assigned_to)
    add_index :service_tickets, :scheduled_date unless index_exists?(:service_tickets, :scheduled_date)
    
    # Only add deleted_at index if the column exists
    if column_exists?(:service_tickets, :deleted_at)
      add_index :service_tickets, :deleted_at unless index_exists?(:service_tickets, :deleted_at)
    end
    
    # Only add customer index if columns exist
    if column_exists?(:service_tickets, :customer_type) && column_exists?(:service_tickets, :customer_id)
      add_index :service_tickets, [:customer_type, :customer_id] unless index_exists?(:service_tickets, [:customer_type, :customer_id])
    end
  end
end
