class CreateCommissionRules < ActiveRecord::Migration[8.0]
  def change
    create_table :commission_rules do |t|
      t.references :company, null: false, foreign_key: true
      
      t.string :name, null: false
      t.string :rule_type, null: false  # flat, percentage, tiered
      t.decimal :rate, precision: 5, scale: 4  # for percentage (e.g., 0.0500 = 5%)
      t.decimal :amount, precision: 10, scale: 2  # for flat amount
      t.jsonb :tiers, default: []  # for tiered: [{min: 0, max: 50000, rate: 0.03}, ...]
      t.boolean :is_active, default: true
      t.text :description

      t.timestamps
    end

    add_index :commission_rules, [:company_id, :is_active]
    add_index :commission_rules, :rule_type
  end
end
