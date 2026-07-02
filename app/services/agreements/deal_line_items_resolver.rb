# frozen_string_literal: true

module Agreements
  # Single source of truth for turning a Deal's line items into the normalized shape
  # used by agreements (both the on-create equipment snapshot and merge field data).
  #
  # Priority order:
  #   1. Selected `deal_desk_scenarios` scenario's `line_items` JSONB (what the rep sees
  #      in the Deal Edit UI's Line Items card and just committed to)
  #   2. `deal_products` (legacy fallback for older deals with no selected scenario, or
  #      when the selected scenario has an empty line_items array)
  #
  # Home identification rule:
  #   A line item is THE home if `source == 'home'` (frontend sets this when the row is
  #   dropped from the inventory picker) OR its source_vehicle_id matches deal.vehicle_id.
  #   Category alone ('home') is NOT enough — a user can mis-tag any row that way. If
  #   multiple rows match, the one matching deal.vehicle_id wins; others become add-ons.
  #
  # Returned shape per item:
  #   {
  #     position:          Integer  # 0-based sort order as shown in the UI
  #     description:       String
  #     name:              String   # alias for description (some templates use `name`)
  #     amount:            Float    # price per unit
  #     price:             Float    # alias
  #     cost:              Float
  #     quantity:          Float
  #     line_total:        Float    # (amount * quantity)
  #     total:             Float    # alias for line_total
  #     category:          String   # 'home'|'land'|'fee'|'accessory'|'product'|'service'|'other'|nil
  #     taxable:           Boolean
  #     source:            String   # 'home'|'deal'|'package'|'manual'|nil (from scenario)
  #     source_vehicle_id: Integer  # nil when the row isn't backed by a Vehicle record
  #     is_home:           Boolean  # derived flag (see home identification rule above)
  #   }
  class DealLineItemsResolver
    HOME_SOURCES = %w[home package].freeze

    def self.call(deal)
      new(deal).call
    end

    def initialize(deal)
      @deal = deal
    end

    # Returns an Array of normalized line item hashes, or [] if nothing usable.
    def call
      return [] unless @deal

      items = from_selected_scenario
      items = from_deal_products if items.empty?
      items
    end

    private

    def from_selected_scenario
      scenario = @deal.deal_desk_scenarios.selected.order(selected_at: :desc, updated_at: :desc).first
      raw = Array(scenario&.line_items)
      raw.each_with_index.map { |item, idx| normalize_scenario_item(item, idx) }
    end

    def from_deal_products
      @deal.deal_products.order(:created_at).each_with_index.map do |dp, idx|
        price = dp.unit_price.to_f
        qty   = (dp.quantity || 1).to_f
        source = dp.source_type.to_s
        source_vehicle_id = %w[home package].include?(source) ? dp.product_id : nil
        {
          position: idx,
          description: dp.product_name || dp.notes.to_s,
          name: dp.product_name || dp.notes.to_s,
          amount: price,
          price: price,
          cost: dp.cost.to_f,
          quantity: qty,
          line_total: (price * qty).round(2),
          total: dp.total.to_f,
          category: nil, # deal_products has no category — leave nil for the caller to bucket
          taxable: dp.tax.to_f > 0,
          source: source.presence,
          source_vehicle_id: source_vehicle_id,
          is_home: home?(source: source, source_vehicle_id: source_vehicle_id)
        }
      end
    end

    def normalize_scenario_item(item, idx)
      h = item.is_a?(Hash) ? item.deep_stringify_keys : {}
      description = h['description'].presence || h['name'].to_s
      price = h['price'].to_f
      qty   = (h['quantity'] || 1).to_f
      source = h['source'].to_s
      source_vehicle_id = h['source_vehicle_id']
      {
        position: idx,
        description: description,
        name: description,
        amount: price,
        price: price,
        cost: h['cost'].to_f,
        quantity: qty,
        line_total: (price * qty).round(2),
        total: (price * qty).round(2),
        category: h['category'].presence,
        taxable: h['taxable'] == true,
        source: source.presence,
        source_vehicle_id: source_vehicle_id,
        is_home: home?(source: source, source_vehicle_id: source_vehicle_id, category: h['category'])
      }
    end

    # A row is THE home if it's tagged as such by source (authoritative — the frontend
    # sets this when the home is added from inventory) OR if the row is backed by the
    # deal's linked Vehicle record. Category 'home' alone is NOT sufficient because a
    # user can manually mis-tag any row — but when combined with a matching
    # source_vehicle_id we accept it.
    def home?(source:, source_vehicle_id:, category: nil)
      return true if HOME_SOURCES.include?(source.to_s)
      return true if source_vehicle_id.present? && @deal.vehicle_id.present? &&
                     source_vehicle_id.to_i == @deal.vehicle_id.to_i
      return true if category.to_s == 'home' && @deal.vehicle_id.present? &&
                     source_vehicle_id.to_i == @deal.vehicle_id.to_i
      false
    end
  end
end
