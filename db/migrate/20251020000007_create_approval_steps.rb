class CreateApprovalSteps < ActiveRecord::Migration[7.0]
  def change
    create_table :approval_steps do |t|
      t.references :approval_workflow, null: false, foreign_key: true
      t.integer :step_order, null: false
      t.references :approver_user, foreign_key: { to_table: :users }
      t.string :status, null: false, default: 'pending'
      t.string :required_action
      t.text :notes

      t.timestamps
    end

    add_index :approval_steps, [:approval_workflow_id, :step_order]
    add_index :approval_steps, :status
  end
end
