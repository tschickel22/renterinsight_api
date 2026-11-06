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
    Totals = Struct.new(:added, :updated, :inactivated, :held, keyword_init: true)

    # @param subscription [DealerCatalogSubscription]
    # @param homes [Array<NormalizedHome>]
    # @param degraded [Boolean] a thin parse — passed through as protect_blanks
    #   so it can never wipe populated dealer data with a blank.
    def self.call(subscription:, homes:, degraded: false)
      company = subscription.company
      return Totals.new(added: 0, updated: 0, inactivated: 0, held: 0) if company.nil?

      totals = Hash.new(0)
      # The homes this dealer carries; the rest the crawl saw come off their
      # inventory now instead of reading as missing (backlog E94).
      wanted, not_wanted = homes.partition { |home| subscription.wants?(home.source_key) }
      not_wanted_keys = not_wanted.map { |home| home.source_key.to_s }

      subscription.ingest_location_ids.each do |location_id|
        result = IngestionService.new(
          company:        company,
          source:         subscription.catalog_source,
          location_id:    location_id,
          protect_blanks: degraded
        ).call(wanted, not_wanted: not_wanted_keys)

        totals[:added]       += result.added
        totals[:updated]     += result.updated
        totals[:inactivated] += result.inactivated
        totals[:held]        += result.held
      end

      Totals.new(added: totals[:added], updated: totals[:updated], inactivated: totals[:inactivated], held: totals[:held])
    end
  end
end
