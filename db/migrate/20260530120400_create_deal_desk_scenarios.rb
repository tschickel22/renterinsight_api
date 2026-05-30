# frozen_string_literal: true

# Deal Desk scenarios — the working scratchpad and unit of persistence. A deal can have
# MANY scenarios (this IS the compare feature); each may reference a different unit
# (unit-swap). Autosaved as the rep works. Never hard-deleted — expired, not pruned.
#
#   status:  active | expired | selected   (selected/closed kept permanently)
#
# Snapshot philosophy: the unit price and cost are SNAPSHOTTED at quote time, not a live
# reference. unit_price_snapshot remembers what was quoted; #price_changed? flags drift
# against the unit's current price. Computed outputs (amount financed, payment, OTD) come
# from DealDesk::Engine. Dealer gross fields are INTERNAL ONLY — never serialized to a
# customer-facing surface.
class CreateDealDeskScenarios < ActiveRecord::Migration[8.0]
  def change
    create_table :deal_desk_scenarios do |t|
      # Tenancy + ownership
      t.references :company,  null: false, foreign_key: true, index: true
      t.references :location, null: true,  foreign_key: true, index: true
      t.references :deal,     null: false, foreign_key: true, index: true
      t.references :vehicle,  null: true,  foreign_key: true, index: true   # the unit (swappable)
      t.references :created_by, null: true, foreign_key: { to_table: :users }, index: true

      t.string  :label                                            # optional rep-given name
      t.string  :status,        null: false, default: 'active'    # active|expired|selected
      t.date    :valid_through                                    # validity window
      t.datetime :selected_at

      # --- Input snapshot ---
      t.decimal :trade_allowance, precision: 15, scale: 2, default: 0
      t.decimal :trade_payoff,    precision: 15, scale: 2, default: 0
      t.decimal :cash_down,       precision: 15, scale: 2, default: 0
      t.decimal :rebates,         precision: 15, scale: 2, default: 0
      t.jsonb   :fees,         null: false, default: {}           # { doc:, title:, license:, prep:, ... }
      t.jsonb   :fni_products, null: false, default: []           # [ { name:, type:, price:, cost: } ]
      t.references :lender_program, null: true, foreign_key: true, index: true
      t.string  :lender_tier                                      # tier label snapshot
      t.decimal :apr,         precision: 6, scale: 3              # resolved rate (percent)
      t.string  :rate_source                                      # manual_override|tier|company_default
      t.integer :term_months
      t.string  :tax_mode,    null: false, default: 'full_price'  # full_price|price_minus_trade
      t.decimal :tax_rate,    precision: 8, scale: 5, default: 0  # fraction (0.08250 = 8.25%)

      # --- Price snapshot (NOT a live reference) ---
      t.decimal :unit_price_snapshot, precision: 15, scale: 2
      t.decimal :unit_cost_snapshot,  precision: 15, scale: 2     # internal (gross stability)

      # --- Computed outputs (from DealDesk::Engine) ---
      t.decimal :amount_financed, precision: 15, scale: 2
      t.decimal :monthly_payment, precision: 15, scale: 2
      t.decimal :out_the_door,    precision: 15, scale: 2
      t.decimal :front_gross,     precision: 15, scale: 2         # internal
      t.decimal :back_gross,      precision: 15, scale: 2         # internal
      t.decimal :dealer_gross,    precision: 15, scale: 2         # internal (total)

      # --- Aged / cross-location metadata (when the unit lives at another lot) ---
      t.bigint  :unit_location_id                                 # unit's home location
      t.integer :unit_days_on_lot                                 # snapshot at scenario time
      t.boolean :is_cross_location, null: false, default: false

      # --- Optional generated quote (a scenario is NOT a quote; one may be made from it) ---
      t.references :quote, null: true, foreign_key: true, index: true

      t.timestamps
    end

    add_index :deal_desk_scenarios, [:company_id, :status]
    add_index :deal_desk_scenarios, [:deal_id, :status]
    add_index :deal_desk_scenarios, :valid_through
  end
end
