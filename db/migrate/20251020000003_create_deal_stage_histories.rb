class CreateDealStageHistories < ActiveRecord::Migration[7.0]
  def change
    create_table :deal_stage_histories do |t|
      t.references :deal, null: false, foreign_key: true
      t.string :stage, null: false
      t.string :previous_stage
      t.references :changed_by, foreign_key: { to_table: :users }
      t.integer :duration
      t.text :notes

      t.timestamps
    end

    add_index :deal_stage_histories, [:deal_id, :created_at]
    add_index :deal_stage_histories, :stage
  end
end
