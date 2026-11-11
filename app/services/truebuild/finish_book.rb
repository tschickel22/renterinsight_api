# frozen_string_literal: true

module Truebuild
  # The finishes a dealer's homes come in, for a Decor page on their site:
  # every color choice in the option books of the models they offer, with
  # the factory's own sample picture and measured color, and no prices.
  #
  # Unlike the designer this does not wait for TrueView. The designer shows
  # only finishes drawn on the home's photos (BuyerCatalog#without_failed_drawings),
  # because a chip there promises a picture; a decor page promises only the
  # sample, which a builder otherwise hands out as a PDF.
  #
  # => [{ name: 'Kitchen', sets: [{ name: 'Cabinet Colors',
  #        options: [{ name:, standard:, hex:, swatch_url:, note: }] }] }]
  class FinishBook
    # A factory's books are shared by its models, so a few models show
    # every finish it offers; a dealer with hundreds of homes must not price
    # every one of them for a decor page.
    MODELS_PER_FACTORY = 3

    def initialize(company)
      @company = company
    end

    def call(factory_ids: nil, series: nil)
      factory_ids = Array(factory_ids).map(&:to_i).reject(&:zero?).sort
      series = Array(series).map(&:to_s).reject(&:blank?).sort
      Rails.cache.fetch(cache_key(factory_ids, series), expires_in: 30.minutes) { build(factory_ids, series) }
    end

    private

    def build(factory_ids, series)
      plans = ModelList.new(@company).call(factory_ids: factory_ids, series: series)
      variants = CatalogPlanVariant.where(id: plans.flat_map { |p| p[:variants].map { |v| v[:id] } })
                                   .includes(:catalog_plan).to_a
      groups = {}
      samples(variants).each do |variant|
        BuyerCatalog.finish_groups(variant).each do |group|
          sets = (groups[group[:name]] ||= {})
          group[:color_sets].each do |set|
            chips = (sets[set[:name]] ||= {})
            set[:options].each { |o| chips[o[:name].downcase] ||= chip(o, variant, set[:name]) }
          end
        end
      end
      groups.filter_map do |name, sets|
        shown = sets.filter_map do |set, chips|
          { name: set, options: chips.values.sort_by { |c| [c[:standard] ? 0 : 1, c[:name]] } } if chips.any?
        end
        { name: name, sets: shown } if shown.any?
      end
    end

    # A few models per factory, spread across its sizes (a single and a
    # double can offer different counters).
    def samples(variants)
      variants.group_by { |v| v.catalog_plan&.factory_id || "m#{v.manufacturer_id}" }.values.flat_map do |vs|
        vs = vs.sort_by { |v| [v.width_ft.to_i, v.length_ft.to_i, v.id] }
        [vs.first, vs[vs.size / 2], vs.last].uniq.first(MODELS_PER_FACTORY)
      end
    end

    def chip(option, variant, set)
      sample = CatalogSwatch.for_finish(manufacturer_id: variant.manufacturer_id, factory_id: variant.catalog_plan&.factory_id,
                                        surface: set, value: option[:name], pool: pool(variant))
      { name: option[:name], standard: option[:standard] ? true : false, hex: option[:hex],
        swatch_url: option[:swatch_url], note: sample&.note.presence }
    end

    def pool(variant)
      @pools ||= {}
      @pools[[variant.manufacturer_id, variant.catalog_plan&.factory_id]] ||=
        CatalogSwatch.where(manufacturer_id: variant.manufacturer_id, factory_id: [variant.catalog_plan&.factory_id, nil].uniq).to_a
    end

    def cache_key(factory_ids, series)
      stamp = [CatalogOption.maximum(:updated_at), CatalogSwatch.maximum(:updated_at), CatalogPriceBook.published.maximum(:published_at),
               CatalogPlanVariant.maximum(:updated_at), @company.dealer_factories.maximum(:updated_at), Factory.maximum(:updated_at)]
              .map { |t| t&.to_i }.join('-')
      "truebuild:finish_book:v1:#{@company.id}:#{factory_ids.join(',')}:#{series.join(',')}:#{stamp}-#{@company.dealer_factories.count}"
    end
  end
end
