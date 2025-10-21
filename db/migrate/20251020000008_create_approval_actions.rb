class CreateApprovalActions < ActiveRecord::Migration[7.0]
  def change
    create_table :approval_actions do |t|
      t.references :approval_step, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :action_type, null: false
      t.text :notes
      t.datetime :actioned_at

      t.timestamps
    end

    add_index :approval_actions, [:approval_step_id, :actioned_at]
    add_index :approval_actions, :action_type
  end
end
