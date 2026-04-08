class CreateWorkflowApprovals < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_approvals do |t|
      t.references :workflow_run, null: false, foreign_key: true, index: true
      t.string :step_id, null: false
      t.references :company, null: false, foreign_key: true, index: true
      t.string :status, null: false, default: 'pending'
      t.references :approver_user, foreign_key: { to_table: :users }, null: true
      t.datetime :approved_at
      t.text :rejection_reason
      t.datetime :expires_at, index: true
      t.timestamps
    end
  end
end
