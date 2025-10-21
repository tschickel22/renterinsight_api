class CreateDeals < ActiveRecord::Migration[7.0]
  def change
    create_table :deals do |t|
      t.string :name, null: false
      t.references :account, null: false, foreign_key: true
      t.decimal :value, precision: 12, scale: 2, default: 0.0
      t.string :stage, null: false, default: 'qualification'
      t.integer :probability, default: 0
      t.date :expected_close_date
      t.date :actual_close_date
      t.references :user, null: false, foreign_key: true
      t.references :territory, null: true  # Foreign key removed to avoid circular dependency
      t.string :lead_source
      t.text :description
      t.text :notes
      t.datetime :won_at
      t.datetime :lost_at
      t.string :win_reason
      t.string :loss_reason
      t.string :competitor
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :deals, :stage
    add_index :deals, :expected_close_date
    add_index :deals, :won_at
    add_index :deals, :lost_at
    add_index :deals, :deleted_at
    add_index :deals, [:account_id, :stage]
    add_index :deals, [:territory_id, :stage]
    add_index :deals, [:user_id, :stage]
  end
end
