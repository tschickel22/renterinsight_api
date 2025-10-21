class CreateWinLossReports < ActiveRecord::Migration[7.0]
  def change
    create_table :win_loss_reports do |t|
      t.references :deal, null: false, foreign_key: true
      t.string :result, null: false
      t.string :primary_reason
      t.string :secondary_reason
      t.string :competitor
      t.text :competitive_advantage
      t.text :competitive_disadvantage
      t.text :customer_feedback
      t.text :internal_notes
      t.text :lessons_learned
      t.integer :deal_quality_score
      t.integer :sales_process_score
      t.integer :product_fit_score
      t.references :user, foreign_key: true

      t.timestamps
    end

    add_index :win_loss_reports, :result
    add_index :win_loss_reports, :primary_reason
    add_index :win_loss_reports, :competitor
    add_index :win_loss_reports, [:deal_id, :result]
  end
end
