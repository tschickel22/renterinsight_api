# frozen_string_literal: true

class CreateContractorAssignments < ActiveRecord::Migration[8.0]
  def change
    create_table :contractor_assignments do |t|
      t.references :contractor, null: false, foreign_key: true
      t.string :assignable_type, null: false
      t.bigint :assignable_id, null: false
      t.references :company, null: false, foreign_key: true
      t.references :assigned_by, foreign_key: { to_table: :users }, null: true
      t.string :status, default: 'assigned'
      t.datetime :assigned_at
      t.datetime :accepted_at
      t.datetime :completed_at
      t.text :notes

      t.timestamps
    end

    add_index :contractor_assignments, [:assignable_type, :assignable_id], name: 'index_contractor_assignments_on_assignable'
    add_index :contractor_assignments, :status
  end
end
