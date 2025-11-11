# frozen_string_literal: true

class CreateBrochures < ActiveRecord::Migration[7.0]
  def change
    create_table :brochures do |t|
      # Company association (tenant isolation)
      t.references :company, null: false, foreign_key: true, index: true

      # Basic information
      t.string :title, null: false
      t.text :description
      t.string :public_id, null: false, index: { unique: true }
      
      # Template information
      t.string :template_name
      t.jsonb :template_data, default: {}
      
      # Vehicle associations
      t.jsonb :vehicle_ids, default: []
      
      # Sharing and tracking
      t.boolean :is_public, default: true
      t.integer :view_count, default: 0
      t.integer :share_count, default: 0
      t.integer :download_count, default: 0
      
      # Status
      t.string :status, default: 'active'
      
      # Soft delete
      t.boolean :is_deleted, default: false
      t.datetime :deleted_at

      t.timestamps
    end

    # Indexes for performance
    add_index :brochures, [:company_id, :is_deleted]
    add_index :brochures, [:company_id, :status]
    add_index :brochures, :created_at
  end
end
