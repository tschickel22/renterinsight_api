# frozen_string_literal: true

# Add dealer_cost and dealer_price to lender_allowance_items so the Max Advance
# calculator knows both the lender ceiling AND the dealer's actual cost/charge.
# Also adds company_allowance_default_id to track which default this was seeded from.
class AddCostPriceToLenderAllowanceItems < ActiveRecord::Migration[8.0]
  def change
    add_column :lender_allowance_items, :dealer_cost,  :decimal, precision: 15, scale: 2
    add_column :lender_allowance_items, :dealer_price, :decimal, precision: 15, scale: 2
    add_column :lender_allowance_items, :position,     :integer, default: 0
    add_reference :lender_allowance_items, :company_allowance_default, foreign_key: true, null: true
  end
end
