# frozen_string_literal: true

# Snapshots the deal's non-home line items (deal_products) onto a Deal Desk
# scenario so the engine can fold add-ons into OTD / front gross (Option B).
# Server-snapshotted only — never client-set in this phase.
class AddLineItemsToDealDeskScenarios < ActiveRecord::Migration[8.0]
  def change
    add_column :deal_desk_scenarios, :line_items, :jsonb, default: []
  end
end
