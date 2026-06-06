# frozen_string_literal: true

# Immutable baseline snapshot captured the FIRST time a Deal Desk unit swap is applied to a
# deal (Section 25, Phase 5). Stores the deal's original economic inputs — vehicle_id, the
# home line item, selling_price/unit_cost/home_cost/value, trade allowance/payoff, down
# payment — so "Revert to original unit" can faithfully restore the deal regardless of any
# later scenario edits or further swaps.
#
# Semantics:
#   - nil           => no swap has ever been applied; nothing to revert to.
#   - present (Hash) => a swap was applied; the blob is the ORIGINAL state. Captured once and
#                       never overwritten by subsequent swaps (single-level revert-to-origin).
# Cleared back to nil on a successful revert so the "revert" affordance disappears.
class AddDealDeskBaselineToDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :deals, :deal_desk_baseline, :jsonb
  end
end
