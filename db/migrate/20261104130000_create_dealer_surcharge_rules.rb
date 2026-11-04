# frozen_string_literal: true

# A dealer's surcharge as a calculation (dollars per square foot or per home, by
# plant and section count), so one number covers every home when a factory
# changes it. The pack on an inventory home is for homes no price book has.
class CreateDealerSurchargeRules < ActiveRecord::Migration[8.0]
  def change
    create_table :dealer_surcharge_rules do |t|
      t.references :company, null: false, foreign_key: true
      t.references :manufacturer, null: false, foreign_key: true
      t.references :factory, foreign_key: true
      t.string :section, null: false, default: 'any'
      t.string :basis, null: false, default: 'per_sq_ft'
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :dealer_surcharge_rules, 'company_id, manufacturer_id, COALESCE(factory_id, 0), section',
              unique: true, name: 'idx_dealer_surcharge_rules_one_per_scope'
    add_column :vehicles, :pack_amount, :decimal, precision: 10, scale: 2
  end
end
