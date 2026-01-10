# frozen_string_literal: true

class CreateDashboardLayouts < ActiveRecord::Migration[8.0]
  def change
    create_table :dashboard_layouts do |t|
      t.references :user, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.string :preset_id, null: false
      t.jsonb :layout_data, default: {}, null: false

      t.timestamps
    end

    add_index :dashboard_layouts, [:user_id, :company_id, :preset_id], 
              unique: true, 
              name: 'index_dashboard_layouts_on_user_company_preset'
  end
end
