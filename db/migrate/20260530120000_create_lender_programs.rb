# frozen_string_literal: true

# Lender programs for the Deal Desk. A program belongs to a lender and carries a
# tier matrix (see lender_program_tiers). The desk reads finance config but does not
# live inside Finance. No real rate sheets exist yet — seeded samples are flagged
# is_seeded: true and are swappable when real sheets arrive.
class CreateLenderPrograms < ActiveRecord::Migration[8.0]
  def change
    create_table :lender_programs do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.string  :lender_name,  null: false
      t.string  :program_name, null: false
      t.string  :collateral_type            # rv | manufactured_home | all
      t.text    :notes
      t.boolean :active,    null: false, default: true
      t.boolean :is_seeded, null: false, default: false
      t.integer :position,  null: false, default: 0
      t.timestamps
    end

    add_index :lender_programs, [:company_id, :active]
  end
end
