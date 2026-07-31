# frozen_string_literal: true

module Catalog
  # Ingests a set of parsed homes into ONE dealer subscription, across whichever
  # locations that subscription targets ([nil] means company-wide).
  #
  # Extracted so the two callers cannot drift: RunService uses it for every
  # subscriber after a crawl, and CatalogSubscriptionsController uses it to
  # backfill a brand-new subscriber from ParsedHomeCache instead of forcing a
  # fresh crawl.
  class SubscriptionIngestor
    Totals = Struct.new(:added, :updated, :inactivated, keyword_init: true)

    # @param subscription [DealerCatalogSubscription]
    # @param homes [Array<NormalizedHome>]
    # @param degraded [Boolean] a thin parse — passed through as protect_blanks
    #   so it can never wipe populated dealer data with a blank.
    def self.call(subscription:, homes:, degraded: false)
      company = subscription.company
      return Totals.new(added: 0, updated: 0, inactivated: 0) if company.nil?

      totals = Hash.new(0)

      subscription.ingest_location_ids.each do |location_id|
        result = IngestionService.new(
          company:        company,
          source:         subscription.catalog_source,
          location_id:    location_id,
          protect_blanks: degraded
        ).call(homes)

        totals[:added]       += result.added
        totals[:updated]     += result.updated
        totals[:inactivated] += result.inactivated
      end

      Totals.new(added: totals[:added], updated: totals[:updated], inactivated: totals[:inactivated])
    end
  end
end
