# frozen_string_literal: true

# What TrueBuild has learned about price book options that their names do not
# say: which are pick-one, which chips are the same finish, which standard
# items are really a color choice, which packages include something sold
# separately. Keyed by the option's stable key, so next year's book from the
# same factory inherits every decision. (catalog_option_rules is the order
# forms' own requires / excludes text, approved by hand.)
class CreateCatalogOptionDecisions < ActiveRecord::Migration[8.0]
  def change
    create_table :catalog_option_decisions do |t|
      t.references :manufacturer, foreign_key: true # null: every manufacturer
      t.string :option_key, null: false
      t.string :kind, null: false
      t.string :value
      t.string :source, null: false, default: 'claude'
      t.string :status, null: false, default: 'active'
      t.string :suggestion # rows suggested together share it
      t.text :note
      t.references :catalog_price_book, foreign_key: { on_delete: :nullify }
      t.references :reviewed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :catalog_option_decisions, %i[manufacturer_id option_key kind], unique: true, name: 'idx_catalog_option_decisions_unique'
    add_index :catalog_option_decisions, :suggestion
  end
end
