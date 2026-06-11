# frozen_string_literal: true

# Reusable fee templates for the Deal Desk (title / license / doc / prep / delivery /
# setup). @company-scoped. Seeded samples are flagged is_seeded: true.
class CreateFeeTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :fee_templates do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.string  :name,        null: false
      t.string  :fee_type,    null: false, default: 'other'  # doc|title|license|prep|delivery|setup|other
      t.decimal :default_amount, precision: 15, scale: 2, null: false, default: 0
      t.boolean :taxable,     null: false, default: false
      t.string  :applies_to,  null: false, default: 'all'    # rv|manufactured_home|all
      t.boolean :active,      null: false, default: true
      t.boolean :is_seeded,   null: false, default: false
      t.integer :position,    null: false, default: 0
      t.timestamps
    end

    add_index :fee_templates, [:company_id, :active]
  end
end
