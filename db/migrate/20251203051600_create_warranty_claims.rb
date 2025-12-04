# frozen_string_literal: true

class CreateWarrantyClaims < ActiveRecord::Migration[8.0]
  def change
    create_table :warranty_claims do |t|
      # Tenant Isolation
      t.bigint :company_id, null: false
      t.bigint :location_id
      
      # Relationships
      t.bigint :service_ticket_id, null: false
      t.bigint :manufacturer_id, null: false
      
      # Claim Numbers
      t.string :claim_number, null: false # Internal tracking number
      t.string :manufacturer_claim_number # Manufacturer's reference number
      
      # Claim Details
      t.decimal :estimated_amount, precision: 10, scale: 2
      t.decimal :approved_amount, precision: 10, scale: 2
      t.decimal :client_copay_amount, precision: 10, scale: 2, default: 0.0
      
      # Parts & Labor (JSONB for flexibility)
      t.jsonb :parts, default: [] # Array of {description, part_number, quantity, cost}
      t.jsonb :labor, default: [] # Array of {description, hours, rate}
      
      # Status Tracking
      t.string :status, null: false, default: 'draft'
      # Statuses: draft, submitted, under_review, approved, denied, short_paid, resubmitted, closed
      
      # Important Dates
      t.datetime :submitted_at
      t.datetime :manufacturer_responded_at
      t.datetime :approved_at
      t.datetime :denied_at
      t.datetime :closed_at
      
      # Notes & Communication
      t.text :notes_internal # Company-only notes
      t.text :notes_to_manufacturer # Notes sent to manufacturer
      t.text :manufacturer_response # Manufacturer's response/reason
      t.text :denial_reason # Why denied (if applicable)
      
      # Public Access (for manufacturer email links - no login required)
      t.string :public_token, null: false # Unique token for public viewing
      t.integer :views_count, default: 0 # Track how many times manufacturer viewed
      
      # Audit Trail
      t.string :submitted_by # User who submitted
      t.string :approved_by # User who finalized
      
      # Soft Delete
      t.boolean :is_deleted, default: false, null: false
      t.datetime :deleted_at
      
      t.timestamps
    end
    
    # Foreign Keys
    add_foreign_key :warranty_claims, :companies, on_delete: :cascade
    add_foreign_key :warranty_claims, :locations, on_delete: :nullify
    add_foreign_key :warranty_claims, :service_tickets, on_delete: :restrict
    add_foreign_key :warranty_claims, :manufacturers, on_delete: :restrict
    
    # Indexes
    add_index :warranty_claims, :company_id
    add_index :warranty_claims, :location_id
    add_index :warranty_claims, :service_ticket_id
    add_index :warranty_claims, :manufacturer_id
    add_index :warranty_claims, [:company_id, :claim_number], unique: true
    add_index :warranty_claims, :public_token, unique: true
    add_index :warranty_claims, :status
    add_index :warranty_claims, [:company_id, :status]
    add_index :warranty_claims, [:company_id, :is_deleted]
    add_index :warranty_claims, :submitted_at
    add_index :warranty_claims, :manufacturer_responded_at
  end
end
