# frozen_string_literal: true

# E106: the dealer adds or changes a task on a phase a linked installer runs
# and sends it to them. The installer answers with a change order or "no
# charge"; until then that phase can't start on the installer's side.
class CreateProjectLinkScopeChanges < ActiveRecord::Migration[8.0]
  def change
    create_table :project_link_scope_changes do |t|
      t.references :project_link, null: false, foreign_key: true
      t.bigint :dealer_phase_id, null: false
      t.bigint :dealer_task_id
      t.bigint :installer_task_id
      t.string :kind, null: false # task_added, task_changed
      t.string :status, null: false, default: 'pending' # pending, no_charge, change_order, withdrawn
      t.text :description, null: false
      t.bigint :requested_by_id
      t.bigint :answered_by_id
      t.datetime :answered_at
      t.bigint :link_change_id
      t.timestamps
    end
    add_index :project_link_scope_changes, %i[project_link_id status]
    add_index :project_link_scope_changes, :dealer_phase_id
  end
end
