# frozen_string_literal: true

module Truebuild
  # A published price book and everything TrueBuild needs around it, copied
  # whole from one environment to another (the "books" step of
  # DrawingTransfer): its manufacturer and factories, the plans and models it
  # prices with their photos, option groups, options, option and base prices,
  # standard features and learned option decisions.
  #
  # Copied rather than imported again from the factory's files: the importer
  # reads them with Claude, a second reading can word an option differently,
  # and a TrueView drawing is found by the option names in its prompt. A
  # copy keeps every name, so the drawings copied after it match.
  #
  # Rows travel by natural keys: a factory by code, a plan by series and
  # slug, a model by series and model number, a group by factory, series and
  # key, an option by key, the book by factory and name. The book's own price
  # rows are replaced on each copy; nothing else on the receiving side is
  # removed. Uploaded source files and extraction review items stay behind:
  # pricing comes from the published rows, not the files.
  module BookTransfer
    module_function

    def scope = CatalogPriceBook.where(status: 'published')

    def export(book)
      option_prices = book.option_prices.includes(:option, :variant).to_a
      variant_prices = book.variant_prices.includes(:variant).to_a
      variants = (variant_prices.map(&:variant) + option_prices.filter_map(&:variant)).uniq
      plans = variants.map(&:catalog_plan).uniq
      options = option_prices.map(&:option).uniq
      options |= CatalogOption.where(id: options.filter_map(&:replaced_by_id)).to_a
      groups = options.map(&:group).uniq
      factories = ([book.factory] + plans.map(&:factory) + groups.map(&:factory)).compact.uniq
      m = book.manufacturer
      {
        id: book.id,
        manufacturer: m.attributes.slice('name', 'industry_type', 'code', 'website', 'logo_url'),
        factories: factories.map { |f| f.attributes.except('id', 'manufacturer_id', 'created_at', 'updated_at', *RELEASE) },
        book: book.attributes.slice('name', 'status', 'effective_on', 'published_at', 'notes', 'metadata')
                  .merge('factory_code' => book.factory&.code),
        plans: plans.map { |p| p.attributes.except('id', 'manufacturer_id', 'factory_id', 'created_at', 'updated_at').merge('factory_code' => p.factory&.code) },
        variants: variants.map do |v|
          v.attributes.except('id', 'manufacturer_id', 'catalog_plan_id', 'created_at', 'updated_at')
           .merge('plan' => plan_key(v.catalog_plan))
        end,
        groups: groups.map { |g| g.attributes.except('id', 'manufacturer_id', 'factory_id', 'created_at', 'updated_at').merge('factory_code' => g.factory&.code) },
        options: options.map do |o|
          o.attributes.except('id', 'manufacturer_id', 'catalog_option_group_id', 'replaced_by_id', 'created_at', 'updated_at')
           .merge('group' => group_key(o.group), 'replaced_by_key' => o.replaced_by&.key)
        end,
        option_prices: option_prices.map do |p|
          p.attributes.except('id', 'catalog_price_book_id', 'catalog_option_id', 'catalog_plan_variant_id', 'created_at', 'updated_at')
           .merge('option_key' => p.option.key, 'variant' => p.variant && variant_key(p.variant))
        end,
        variant_prices: variant_prices.map do |p|
          p.attributes.except('id', 'catalog_price_book_id', 'catalog_plan_variant_id', 'created_at', 'updated_at')
           .merge('variant' => variant_key(p.variant))
        end,
        standard_features: book.standard_features.map { |f| f.attributes.except('id', 'catalog_price_book_id', 'created_at', 'updated_at') },
        decisions: CatalogOptionDecision.where(manufacturer_id: m.id).map do |d|
          d.attributes.except('id', 'manufacturer_id', 'catalog_price_book_id', 'reviewed_by_id', 'created_at', 'updated_at')
           .merge('from_this_book' => d.catalog_price_book_id == book.id)
        end
      }
    end

    # Another published book for the same factory on this side: replacing it
    # is a decision for a person, not a copy.
    def published_elsewhere(row)
      m = Manufacturer.find_by(name: row['manufacturer']['name']) or return nil
      code = row['book']['factory_code']
      factory = code && m.factories.find_by(code: code)
      return nil if code && !factory

      CatalogPriceBook.published.where(manufacturer_id: m.id, factory_id: factory&.id).where.not(name: row['book']['name']).first
    end

    RELEASE = %w[truebuild_released_at truebuild_released_by_id truebuild_release_note].freeze

    def plan_key(p) = { 'series' => p.series, 'slug' => p.slug }
    def variant_key(v) = { 'series' => v.series, 'model_number' => v.model_number }
    def group_key(g) = { 'factory_code' => g.factory&.code, 'series' => g.series, 'key' => g.key }

    # => :created or :updated, or a String saying why it was not copied.
    def import!(row)
      if (conflict = published_elsewhere(row))
        return "#{conflict.name} is already the published book for this factory here"
      end

      ActiveRecord::Base.transaction do
        m = Manufacturer.find_or_create_by!(name: row['manufacturer']['name']) do |x|
          x.assign_attributes(row['manufacturer'].except('name'))
        end
        factories = row['factories'].to_h do |attrs|
          f = m.factories.find_or_initialize_by(code: attrs['code'])
          # Keep the receiving side's own release decision (E64).
          f.assign_attributes(attrs.except('code'))
          f.save!
          [f.code, f]
        end
        factory_id = ->(code) { code && factories.fetch(code).id }

        plans = row['plans'].to_h do |attrs|
          p = CatalogPlan.find_or_initialize_by(manufacturer_id: m.id, series: attrs['series'], slug: attrs['slug'])
          p.assign_attributes(attrs.except('factory_code').merge('factory_id' => factory_id.call(attrs['factory_code'])))
          p.save!
          [[p.series, p.slug], p]
        end
        variants = row['variants'].to_h do |attrs|
          v = CatalogPlanVariant.find_or_initialize_by(manufacturer_id: m.id, series: attrs['series'], model_number: attrs['model_number'])
          media = attrs['media'].to_h
          # A model the receiving side already has keeps its photos; only the
          # TrueView photo choices come across.
          media = (v.media || {}).merge(media.slice(*DrawingTransfer::PHOTO_KEYS)) unless v.new_record?
          v.assign_attributes(attrs.except('plan', 'media').merge('media' => media,
                                                                  'catalog_plan_id' => plans.fetch(attrs['plan'].values_at('series', 'slug')).id))
          v.save!
          [[v.series, v.model_number], v]
        end
        groups = row['groups'].to_h do |attrs|
          g = CatalogOptionGroup.find_or_initialize_by(manufacturer_id: m.id, factory_id: factory_id.call(attrs['factory_code']),
                                                       series: attrs['series'], key: attrs['key'])
          g.assign_attributes(attrs.except('factory_code'))
          g.save!
          [[attrs['factory_code'], g.series, g.key], g]
        end
        options = row['options'].to_h do |attrs|
          o = CatalogOption.find_or_initialize_by(manufacturer_id: m.id, key: attrs['key'])
          o.assign_attributes(attrs.except('group', 'replaced_by_key', 'swatch_url')
                                   .merge('catalog_option_group_id' => groups.fetch(attrs['group'].values_at('factory_code', 'series', 'key')).id))
          o.swatch_url = DrawingTransfer.rehost(attrs['swatch_url']) if attrs['swatch_url'].present? && o.swatch_url.blank?
          o.save!
          [o.key, o]
        end
        row['options'].each do |attrs|
          next unless attrs['replaced_by_key'] && options[attrs['replaced_by_key']]

          options[attrs['key']].update_columns(replaced_by_id: options[attrs['replaced_by_key']].id)
        end

        attrs = row['book']
        book = CatalogPriceBook.find_or_initialize_by(manufacturer_id: m.id, factory_id: factory_id.call(attrs['factory_code']), name: attrs['name'])
        created = book.new_record?
        book.assign_attributes(attrs.except('factory_code'))
        book.save!
        now = Time.current
        stamp = ->(h) { h.merge('catalog_price_book_id' => book.id, 'created_at' => now, 'updated_at' => now) }
        book.option_prices.delete_all
        prices = row['option_prices'].map do |p|
          variant = p['variant'] && variants.fetch(p['variant'].values_at('series', 'model_number'))
          stamp.call(p.except('option_key', 'variant').merge('catalog_option_id' => options.fetch(p['option_key']).id,
                                                             'catalog_plan_variant_id' => variant&.id))
        end
        CatalogOptionPrice.insert_all!(prices) if prices.any?
        book.variant_prices.delete_all
        base = row['variant_prices'].map do |p|
          stamp.call(p.except('variant').merge('catalog_plan_variant_id' => variants.fetch(p['variant'].values_at('series', 'model_number')).id))
        end
        CatalogVariantPrice.insert_all!(base) if base.any?
        book.standard_features.delete_all
        CatalogStandardFeature.insert_all!(row['standard_features'].map(&stamp)) if row['standard_features'].any?

        row['decisions'].each do |d|
          decision = CatalogOptionDecision.find_or_initialize_by(manufacturer_id: m.id, option_key: d['option_key'], kind: d['kind'])
          next unless decision.new_record? # a decision made here stands

          decision.update!(d.except('from_this_book').merge('catalog_price_book_id' => (book.id if d['from_this_book'])))
        end
        book.touch
        created ? :created : :updated
      end
    end
  end
end
