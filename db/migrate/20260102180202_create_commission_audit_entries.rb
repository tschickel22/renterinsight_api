class CreateCommissionAuditEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :commission_audit_entries do |t|
      t.references :commission, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true  # user who made the change
      
      t.string :action, null: false  # created, updated, approved, rejected, paid, cancelled
      t.jsonb :previous_value
      t.jsonb :new_value
      t.text :notes

      t.timestamp :created_at, null: false
    end

    add_index :commission_audit_entries, [:commission_id, :created_at]
    add_index :commission_audit_entries, :action
  end
end
