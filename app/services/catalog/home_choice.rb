# frozen_string_literal: true

module Catalog
  # Which of a feed's homes one dealer carries (backlog E94), for the tick list
  # beside a subscription and for saving it.
  #
  # The list comes from the source's last parse (ParsedHomeCache), at any age:
  # it is a list to choose from, not data to ingest. With no parse yet, it is
  # the homes the dealer already has from the source. Each home says whether a
  # price book the dealer can quote from prices it, which is how a dealer who
  # sells only what is on their price list (Easy Homesource) decides.
  module HomeChoice
    module_function

    LIST_AGE = 365.days
    NUMBER = /\d{5}[A-Z0-9]\z/

    def homes(subscription)
      source = subscription.catalog_source
      cached = ParsedHomeCache.read(source, max_age: LIST_AGE)
      have = subscription.company.vehicles.where(catalog_source_id: source.id)
      live = have.where(is_deleted: [false, nil]).pluck(:catalog_source_key).map(&:to_s).to_set
      kept_anyway = have.where(is_deleted: [false, nil]).select { |v| v.has_dealer_activity? || v.status != 'available_to_order' }
                        .map { |v| v.catalog_source_key.to_s }.to_set
      priced = PricedNumbers.new(subscription.company, source)

      rows = if cached
               cached.map do |h|
                 { key: h.source_key.to_s, name: h.model_name.to_s, number: h.model_id.to_s, series: h.series,
                   beds: h.bedrooms, baths: h.bathrooms, size: h.dimensions, photo: photo_of(h) }
               end
             else
               have.where(is_deleted: [false, nil]).map do |v|
                 { key: v.catalog_source_key.to_s, name: [v.model, v.make].compact.first.to_s, number: v.model.to_s[NUMBER], series: nil,
                   beds: v.bedrooms, baths: v.bathrooms, size: [v.width, v.length].compact.join(' x ').presence, photo: v.photo_url }
               end
             end

      list = rows.uniq { |r| r[:key] }.map do |r|
        r.merge(kept: subscription.wants?(r[:key]), waiting: subscription.waiting?(r[:key]),
                in_inventory: live.include?(r[:key]), stays: kept_anyway.include?(r[:key]),
                in_price_book: priced.include?(r[:name], r[:number], r[:series]))
      end
      { homes: list.sort_by { |r| [r[:series].to_s, r[:name].downcase] }, from: cached ? 'feed' : 'inventory',
        cached_at: ParsedHomeCache.cached_at(source)&.iso8601 }
    end

    def photo_of(home)
      shots = Array(home.images).select { |i| i.is_a?(Hash) }.map(&:stringify_keys)
      pick = shots.find { |i| !i['is_floorplan'] } || shots.first
      pick && (pick['local_url'].presence || pick['source_url'].presence || pick['url'].presence)
    end

    # Saves the dealer's choice over the homes shown and applies it to their
    # inventory now, from the last parse, so they see the result at once.
    def apply!(subscription, shown_keys:, kept_keys:, new_homes:)
      subscription.choose!(shown_keys: shown_keys, kept_keys: kept_keys, new_homes: new_homes)
      homes = ParsedHomeCache.read(subscription.catalog_source, max_age: LIST_AGE)
      return { applied: false } if homes.blank?

      totals = SubscriptionIngestor.call(subscription: subscription, homes: homes,
                                         degraded: ParsedHomeCache.degraded?(subscription.catalog_source))
      { applied: true, added: totals.added, updated: totals.updated, removed: totals.inactivated }
    end

    # Model numbers a price book prices for this dealer, from the factories
    # they are given. A number several series share (Cavco's 15763A is Cavco
    # Select and Craft Select) counts only when the name agrees as well.
    class PricedNumbers
      def initialize(company, source)
        factory_ids = company.dealer_factories.pluck(:factory_id)
        scope = CatalogPlanVariant.joins(:catalog_plan).where(catalog_plans: { factory_id: factory_ids })
                                  .where(id: CatalogVariantPrice.where(catalog_price_book_id: CatalogPriceBook.published.select(:id))
                                                                .select(:catalog_plan_variant_id))
        scope = scope.where(manufacturer_id: source.manufacturer_id) if source.manufacturer_id
        @by_number = scope.includes(:catalog_plan).group_by { |v| v.model_number.to_s.upcase }
      end

      def include?(name, number, series = nil)
        number = number.to_s.upcase
        candidates = @by_number[number] || @by_number[number[NUMBER].to_s] || []
        return false if candidates.empty?

        words = Truebuild::CavcoModelMedia.name_words(name) | Truebuild::CavcoModelMedia.name_words(series)
        named = candidates.map do |v|
          Truebuild::CavcoModelMedia.name_words(v.catalog_plan&.name.to_s.sub(/\s*#{Regexp.escape(v.model_number.to_s)}\z/i, '')) |
            Truebuild::CavcoModelMedia.name_words(v.catalog_plan&.series)
        end
        words.empty? || named.all?(&:empty?) || named.any? { |w| w.intersect?(words) }
      end
    end
  end
end
