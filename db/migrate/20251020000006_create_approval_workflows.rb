class CreateApprovalWorkflows < ActiveRecord::Migration[7.0]
  def change
    create_table :approval_workflows do |t|
      t.references :deal, null: false, foreign_key: true
      t.string :workflow_type, null: false
      t.string :status, null: false, default: 'pending'
      t.decimal :required_amount, precision: 12, scale: 2
      t.text :reason
      t.text :notes
      t.references :requested_by, foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :approved_at

      t.timestamps
    end

    add_index :approval_workflows, [:deal_id, :status]
    add_index :approval_workflows, :workflow_type
    add_index :approval_workflows, :status
  end
end
