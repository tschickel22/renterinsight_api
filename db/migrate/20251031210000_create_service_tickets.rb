# frozen_string_literal: true

class CreateServiceTickets < ActiveRecord::Migration[7.2]
  def change
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
    
    add_index :service_tickets, :status
    add_index :service_tickets, :priority
    add_index :service_tickets, :assigned_to
    add_index :service_tickets, :scheduled_date
    add_index :service_tickets, :deleted_at
    add_index :service_tickets, [:customer_type, :customer_id]
  end
end
