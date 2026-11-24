# frozen_string_literal: true

# Commission worksheet and plan flexibility (2026-11-24):
#   - a component can pay at least / at most a set amount per deal, and pay by
#     gross bands (tiers) instead of one rate;
#   - a deal can override the plan's split between two salespeople;
#   - a manager can add a one-off adjustment to what someone earns on a deal.
# All additive, so the code running during the release keeps working.
class AddCommissionPlanFlexibility < ActiveRecord::Migration[8.0]
  def change
    add_column :commission_components, :min_amount, :decimal, precision: 15, scale: 2
    add_column :commission_components, :max_amount, :decimal, precision: 15, scale: 2
    add_column :commission_components, :tiers, :jsonb, default: [], null: false

    add_column :deals, :commission_split_primary_pct, :decimal, precision: 5, scale: 2

    create_table :commission_adjustments do |t|
      t.bigint :company_id, null: false
      t.bigint :deal_id, null: false
      t.bigint :payee_user_id, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.string :reason, null: false
      t.bigint :created_by_user_id
      t.boolean :is_deleted, default: false, null: false
      t.timestamps
    end
    add_index :commission_adjustments, %i[company_id deal_id]
  end
end
