class CreateCommissions < ActiveRecord::Migration[8.0]
  def change
    # Drop existing table if it exists (from incomplete migration)
    drop_table :commissions, if_exists: true
    
    # Clean up any orphaned indexes from failed migration
    execute <<-SQL
      DROP INDEX IF EXISTS index_commissions_on_company_id_and_status;
      DROP INDEX IF EXISTS index_commissions_on_user_id_and_status;
      DROP INDEX IF EXISTS index_commissions_on_deal_id;
      DROP INDEX IF EXISTS index_commissions_on_location_id;
      DROP INDEX IF EXISTS index_commissions_on_commission_type;
      DROP INDEX IF EXISTS index_commissions_on_paid_date;
    SQL
    
    create_table :commissions do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.references :deal, null: false, foreign_key: true, index: true
      t.references :user, null: false, foreign_key: true, index: false
      t.references :commission_rule, foreign_key: true, index: true
      t.references :location, foreign_key: true, index: true
      
      t.string :commission_type, null: false  # flat, percentage, tiered
      t.decimal :rate, precision: 5, scale: 4  # percentage rate (e.g., 0.0500 = 5%)
      t.decimal :amount, precision: 10, scale: 2, null: false  # calculated commission amount
      t.string :status, null: false, default: 'pending'  # pending, approved, paid, cancelled
      t.date :paid_date
      t.text :notes
      t.jsonb :custom_fields, default: {}

      t.timestamps
    end

    # Composite indexes for common queries
    add_index :commissions, [:company_id, :status]
    add_index :commissions, [:user_id, :status]
    
    # Single column indexes
    add_index :commissions, :commission_type
    add_index :commissions, :paid_date
  end
end
