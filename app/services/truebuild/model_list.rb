# frozen_string_literal: true

module Truebuild
  # Every model a dealer can offer through TrueBuild, for a "Design your home"
  # block on their site: plans with a photo, sizes, and a starting price or
  # monthly estimate as the dealer shows prices. Cached per dealer; the key
  # moves when their rules, terms or the published books change.
  class ModelList
    def initialize(company)
      @company = company
      @terms = DealerCatalogTerm.effective(company, nil)
      @payments = PaymentEstimate.new(company)
    end

    def call(manufacturer_id: nil)
      # Only manufacturers with a published book: an arbitrary id must not
      # force a fresh, expensive build on every request.
      manufacturer_id = nil unless manufacturer_id.blank? || CatalogPriceBook.published.exists?(manufacturer_id: manufacturer_id)
      manufacturer_id = manufacturer_id.presence&.to_i
      Rails.cache.fetch(cache_key(manufacturer_id), expires_in: 30.minutes) { build(manufacturer_id) }
    end

    private

    def build(manufacturer_id)
      return [] unless @company.dealer_markup_rules.active.exists? || @company.dealer_catalog_terms.exists?

      books = CatalogPriceBook.published
      books = books.where(manufacturer_id: manufacturer_id) if manufacturer_id
      variants = CatalogPlanVariant.where(id: CatalogVariantPrice.where(catalog_price_book_id: books.select(:id)).select(:catalog_plan_variant_id))
                                   .where(status: 'active').includes(:catalog_plan, :manufacturer).to_a

      variants.group_by(&:catalog_plan).filter_map do |plan, vs|
        priced = vs.filter_map { |v| (r = base_retail(v)) ? [v, r] : nil }
        next if priced.empty? # no retail for any size: nothing a buyer can price

        cheapest = priced.min_by { |_, r| r }
        media = vs.map(&:shown_media).find { |m| m.present? && (Array(m['photos']).any? || Array(m['elevations']).any?) } || {}
        {
          plan_id: plan.id, name: plan.name, series: plan.series, manufacturer: vs.first.manufacturer&.name,
          image: Array(media['elevations']).first || media.dig('photos', 0, 'url'),
          beds: vs.map(&:beds).compact.uniq.sort, baths: vs.map { |v| v.baths&.to_f }.compact.uniq.sort,
          sizes: vs.filter_map { |v| "#{v.width_ft}' x #{v.length_ft}'" if v.width_ft && v.length_ft }.uniq,
          starting_price: show_prices? ? cheapest[1] : nil,
          starting_monthly: show_monthly? && cheapest[1] ? @payments.monthly(cheapest[1]) : nil,
          variants: vs.sort_by { |v| [v.width_ft.to_i, v.length_ft.to_i, v.model_number] }
                      .map { |v| { id: v.id, model_number: v.model_number, building_code: v.building_code, beds: v.beds,
                                   baths: v.baths&.to_f, width_ft: v.width_ft, length_ft: v.length_ft } }
        }
      end.sort_by { |p| [p[:image] ? 0 : 1, p[:series].to_s, p[:name].to_s] } # photographed homes lead
    end

    def base_retail(variant)
      BuyerCatalog.starting_retail(PricingEngine.new(company: @company, variant: variant).call.lines)
    rescue ArgumentError
      nil
    end

    def show_prices? = BuyerCatalog::SHOWS_PRICES.include?(@terms.price_display)
    def show_monthly? = BuyerCatalog::SHOWS_MONTHLY.include?(@terms.price_display) && @payments.enabled?

    def cache_key(manufacturer_id)
      stamp = [@company.dealer_markup_rules.maximum(:updated_at), @company.dealer_catalog_terms.maximum(:updated_at),
               @company.truebuild_addons.maximum(:updated_at),
               @company.dealer_price_book_adoptions.maximum(:updated_at), CatalogPriceBook.published.maximum(:published_at),
               CatalogPlanVariant.maximum(:updated_at), @company.updated_at].map { |t| t&.to_i }.join('-')
      "truebuild:models:#{@company.id}:#{manufacturer_id}:#{stamp}"
    end
  end
end
