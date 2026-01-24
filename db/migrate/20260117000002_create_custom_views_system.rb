# frozen_string_literal: true

class CreateCustomViewsSystem < ActiveRecord::Migration[8.0]
  def change
    # Custom Views - Save different table configurations per module
    create_table :custom_views do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.string :module, null: false # 'parts', 'suppliers', 'purchase_orders', etc.
      t.string :view_type, default: 'table' # 'table', 'card', 'timeline', 'kanban'
      t.boolean :is_default, default: false
      t.boolean :is_shared, default: false # Shared with all company users
      t.jsonb :filters, default: {} # Saved filter state
      t.jsonb :sort_config, default: {} # Default sort
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
      
      t.index [:company_id, :module]
      t.index [:company_id, :module, :is_default]
      t.index [:created_by_id, :module]
    end
    
    # Custom View Columns - Which fields show in each view
    create_table :custom_view_columns do |t|
      t.references :custom_view, null: false, foreign_key: true
      t.string :field_key, null: false # Can be core field OR custom_field.field_key
      t.boolean :is_custom_field, default: false
      t.integer :display_order, default: 0
      t.integer :width_pixels # Column width
      t.boolean :is_visible, default: true
      t.boolean :is_sortable, default: true
      t.boolean :is_filterable, default: true
      t.timestamps
      
      t.index [:custom_view_id, :display_order]
      t.index [:custom_view_id, :field_key], unique: true
    end
    
    # Field Permissions - RBAC for custom fields (enterprise feature)
    create_table :custom_field_permissions do |t|
      t.references :custom_field, null: false, foreign_key: true
      t.references :role, null: false, foreign_key: true
      t.string :permission_level, null: false # 'hidden', 'read', 'write'
      t.timestamps
      
      t.index [:custom_field_id, :role_id], unique: true
    end
    
    # User View Preferences - Track which view each user last used
    create_table :user_view_preferences do |t|
      t.references :user, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.string :module, null: false
      t.references :active_view, foreign_key: { to_table: :custom_views }
      t.timestamps
      
      t.index [:user_id, :company_id, :module], unique: true
    end
  end
end
