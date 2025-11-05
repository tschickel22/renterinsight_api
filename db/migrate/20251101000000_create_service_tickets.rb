# frozen_string_literal: true

class CreateServiceTickets < ActiveRecord::Migration[8.0]
  def change
    create_table :service_tickets do |t|
      # References
      t.references :company, null: false, foreign_key: true
      t.references :account, null: true, foreign_key: true
      t.references :contact, null: true, foreign_key: true
      t.references :vehicle, null: true, foreign_key: true
      
      # Core fields
      t.string :title, null: false
      t.text :description, null: false
      t.string :status, null: false, default: 'open'
      t.string :priority, null: false, default: 'medium'
      t.string :assigned_to
      t.date :scheduled_date
      t.text :notes
      
      # Parts and Labor (JSON for flexibility - Rails uses jsonb in Postgres, json in SQLite)
      t.json :parts, default: []
      t.json :labor, default: []
      
      # Custom fields
      t.json :custom_fields, default: {}
      
      t.timestamps
    end
    
    # Indexes
    add_index :service_tickets, :status
    add_index :service_tickets, :priority
    add_index :service_tickets, :scheduled_date
    add_index :service_tickets, [:company_id, :status]
  end
end
