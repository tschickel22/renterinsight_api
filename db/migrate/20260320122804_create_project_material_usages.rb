# frozen_string_literal: true

class CreateProjectMaterialUsages < ActiveRecord::Migration[8.0]
  def change
    create_table :project_material_usages do |t|
      t.references :company, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :project_phase, null: true, foreign_key: true
      t.references :project_task, null: true, foreign_key: true
      t.references :part, null: false, foreign_key: true
      t.references :location, null: false, foreign_key: true
      t.references :bin, null: true, foreign_key: { on_delete: :nullify }
      t.decimal :quantity_allocated, precision: 10, scale: 2, null: false, default: 0
      t.decimal :quantity_checked_out, precision: 10, scale: 2, null: false, default: 0
      t.decimal :quantity_used, precision: 10, scale: 2, null: false, default: 0
      t.decimal :quantity_returned, precision: 10, scale: 2, null: false, default: 0
      t.decimal :unit_cost, precision: 12, scale: 2
      t.string :status, default: 'allocated'
      t.datetime :checked_out_at
      t.references :checked_out_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :used_at
      t.references :used_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :returned_at
      t.references :returned_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :notes
      t.boolean :is_deleted, default: false

      t.timestamps
    end

    add_index :project_material_usages, :status
  end
end
