# frozen_string_literal: true

module Catalog
  module Adapters
    # Every model one Cavco plant builds, whatever Cavco assigned to which
    # dealer. Cavco's floorplans carry `plant_location_id` (a string: "34" is
    # Palm Harbor Plant City, "577" Ocala), and its retailer records list the
    # plants a dealer buys from. A dealer's own assignment (cavco_retailer) can
    # miss models the plant builds: Easy Homesource's left out 15 of Plant
    # City's 99 (2026-11-05). One shared source per plant serves every dealer
    # that buys from it.
    #
    #   config: { "plant" => { "id" => "34", "name" => "Plant City" } }
    #
    # Parsing, photos and sizes are the retailer adapter's; only the filter and
    # the dealer-specific bits (in stock, the dealer's lot) differ.
    class CavcoPlantAdapter < CavcoRetailerAdapter
      def plant_id
        return nil unless source.config.is_a?(Hash)

        (source.config.dig('plant', 'id').presence || source.config['plant_id'].presence)&.to_s
      end

      # No dealer, so no dealer's lot: stock belongs to the retailer sources.
      def retailer_id = nil
      def in_stock_count = nil
      def inventory_documents = []
      def include_inventory? = false

      def discovery_hint
        return 'No plant is bound to this source. Set config plant.id to the Cavco plant number.' if plant_id.blank?

        "Cavco returned no floorplans for plant #{plant_id}. The plant may have closed or been renumbered."
      end

      private

      def floorplan_filters
        raise Catalog::CavcoSearchClient::Error, 'no plant id configured' if plant_id.blank?

        # The engine rejects a number here (HTTP 400); the field is text.
        { 'all' => [{ 'type' => 'floorplan' }, { 'plant_location_id' => plant_id }] }
      end

      def raw_extras(raw)
        super.merge('in_stock' => false, 'plant_id' => plant_id)
      end
    end
  end
end
