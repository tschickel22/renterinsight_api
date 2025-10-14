# frozen_string_literal: true

class CreatePortalDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :portal_documents do |t|
      # Polymorphic association to buyer (Lead or Account)
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      
      # Document metadata
      t.string :category
      t.text :description
      
      # Optional relationship to other records (Quote, etc)
      t.string :related_to_type
      t.bigint :related_to_id
      
      # Tracking
      t.string :uploaded_by, default: 'buyer'  # 'buyer' or 'staff'
      t.datetime :uploaded_at
      
      t.timestamps
      
      t.index [:owner_type, :owner_id], name: 'index_portal_documents_on_owner'
      t.index [:related_to_type, :related_to_id], name: 'index_portal_documents_on_related_to'
      t.index :category
      t.index :uploaded_at
    end
  end
end
