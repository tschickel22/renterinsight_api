# frozen_string_literal: true

class CreateCommissionPlans < ActiveRecord::Migration[8.0]
  def change
    create_table :commission_plans do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.references :location, null: true, foreign_key: { on_delete: :nullify }
      
      t.string :name, null: false
      t.text :description
      
      # Assignment filters (plan applies to users matching these criteria)
      t.bigint :assigned_user_id, null: true, comment: 'If set, plan only applies to this specific user'
      t.string :assigned_role, null: true, comment: 'If set, plan applies to users with this role'
      
      # Date range when plan is active
      t.date :effective_date, null: false, default: -> { 'CURRENT_DATE' }
      t.date :expiration_date, null: true, comment: 'NULL = no expiration'
      
      # Status flags
      t.boolean :is_active, null: false, default: true
      t.boolean :is_default, null: false, default: false, comment: 'Company-wide default plan (no user/role filter)'
      
      # Metadata
      t.integer :display_order, default: 0
      t.jsonb :metadata, default: {}, null: false
      
      t.timestamps
    end
    
    # Indexes for performance
    add_index :commission_plans, [:company_id, :is_active]
    add_index :commission_plans, [:company_id, :is_default]
    add_index :commission_plans, [:assigned_user_id], where: 'assigned_user_id IS NOT NULL'
    add_index :commission_plans, [:assigned_role], where: 'assigned_role IS NOT NULL'
    add_index :commission_plans, [:effective_date, :expiration_date]
    
    # Foreign key for assigned_user_id
    add_foreign_key :commission_plans, :users, column: :assigned_user_id, on_delete: :nullify
    
    # Add plan reference to commission_components
    add_reference :commission_components, :commission_plan, null: true, foreign_key: { on_delete: :cascade }
    
    # Add plan reference to commission_payments for tracking which plan was used
    add_reference :commission_payments, :commission_plan, null: true, foreign_key: { on_delete: :nullify }
    
    # Add earned_date to commission_payments (when commission was earned vs when paid)
    add_column :commission_payments, :earned_date, :date, null: true
    add_index :commission_payments, :earned_date
  end
end
