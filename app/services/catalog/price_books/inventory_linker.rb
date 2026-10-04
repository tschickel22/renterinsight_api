# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Which factory model a home on a lot is. Champion IMS feeds, wherever the
    # dealer is, give each home the same model id Champion's site uses, and a
    # price book matched to that site carries the id on its variants. So a home
    # arriving in any dealer's feed can find its factory prices on save.
    module InventoryLinker
      module_function

      # @return [CatalogPlanVariant, nil]
      def variant_for(vehicle)
        id = vehicle.champion_model_id.presence or return nil

        candidates = CatalogPlanVariant.active.where("external_ids->>'champion_model_id' = ?", id).to_a
        return candidates.first if candidates.size <= 1

        # The HUD and modular builds of one plan share a site model; the feed
        # says which this home is.
        code = vehicle.champion_raw_payload&.dig('buildingCode', 'code').to_s.upcase
        by_code = candidates.select { |v| v.building_code == code }
        return by_code.first if by_code.size == 1

        # Still ambiguous: leave it unlinked rather than guess a price.
        nil
      end

      # Link every unlinked home carrying one of these Champion ids.
      def link_all(champion_model_ids)
        Vehicle.where(champion_model_id: champion_model_ids, catalog_plan_variant_id: nil).find_each do |v|
          variant = variant_for(v)
          v.update_columns(catalog_plan_variant_id: variant.id) if variant
        end
      end
    end
  end
end
