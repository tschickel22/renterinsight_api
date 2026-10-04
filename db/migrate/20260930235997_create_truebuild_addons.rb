# frozen_string_literal: true

# A dealer's own packages and fees (their existing package and fee
# templates) brought into TrueBuild: always in the price (delivery, setup),
# offered to the buyer (skirting, steps), or added only to the rep's quote.
class CreateTruebuildAddons < ActiveRecord::Migration[8.0]
  def change
    create_table :truebuild_addons do |t|
      t.references :company, null: false, foreign_key: true
      t.string :source_type, null: false
      t.bigint :source_id, null: false
      t.string :mode, null: false, default: 'included'
      t.decimal :price_override, precision: 12, scale: 2
      t.references :manufacturer, foreign_key: true
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :truebuild_addons, %i[company_id source_type source_id], unique: true
  end
end
