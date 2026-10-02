# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Turns a reviewed book into catalog rows and publishes it, in one
    # transaction. Only approved or edited items go in; the book cannot be
    # published while anything is still pending.
    class Publisher
      class NotReady < StandardError; end

      ACCEPTED = %w[approved edited].freeze

      def initialize(book, by:)
        @book = book
        @user = by
        @mfr = book.manufacturer_id
      end

      def call
        pending = @book.import_items.pending.count
        raise NotReady, "#{pending} items still need review" if pending.positive?
        raise NotReady, 'Nothing was approved' unless @book.import_items.where(review_status: ACCEPTED).exists?

        preflight!

        counts = Hash.new(0)
        CatalogPriceBook.transaction do
          items(:variant_price).each { |i| publish_variant_price(i, counts) }
          coded = items(:option).select { |i| i.payload['kind'] == 'coded' }
          items(:option_price).each { |i| publish_option_price(i, coded, counts) }
          coded.each { |i| publish_coded_option(i, counts) }
          items(:option).select { |i| i.payload['kind'] == 'color' }.each { |i| publish_color(i, counts) }
          items(:standard_feature).each { |i| publish_standard(i, counts) }
          counts['product_changes'] = items(:product_change).size

          @book.update!(metadata: @book.metadata.merge('published_counts' => counts))
          @book.publish!(by: @user)
          counts['plants_labelled'] = Plants.label_series(@book).size
          Truebuild::PriceBookNotifier.hold_for_review(@book)
          link_inventory
        end
        CatalogPriceBookNoticeJob.perform_later(@book.id)
        CatalogModelMediaJob.perform_later(@book.manufacturer_id)
        CatalogOptionReviewJob.perform_later(@book.id)
        counts
      end

      private

      # Every approved row must be priceable before anything is written. An
      # option with only a retail price gets its cost from the tab's markup
      # (noted on the item); anything else is listed for the admin, rather
      # than failing halfway with a database error.
      def preflight!
        problems = []
        items(:variant_price).each do |i|
          next if i.change_type == 'removed' || i.payload['net_base_price'].to_f.positive?

          problems << "#{i.payload['model_number']}: no base price"
        end
        items(:option_price).each do |i|
          p = i.payload
          # Credits and $0 no-charge options are prices; only blank is missing.
          next if p['is_standard'] == true || !p['dealer_cost'].nil?

          retail = p['suggested_retail']
          markup = p['markup'].to_f
          if !retail.nil? && markup.positive?
            retail = retail.to_f
            cost = (retail / markup).round(2)
            note = "Cost #{format('%.2f', cost)} worked out from retail #{format('%.2f', retail)} at the tab's #{markup} markup."
            i.update_columns(payload: p.merge('dealer_cost' => cost, 'resolution' => [p['resolution'], note].compact.join(' ')))
          else
            problems << "#{p['description']} (#{p['tab']}): enter its cost or reject it"
          end
        end
        # Reload so publishing uses the costs worked out above.
        @items = nil
        return if problems.empty?

        more = problems.size > 5 ? " and #{problems.size - 5} more" : ''
        raise NotReady, "#{problems.size} approved rows have no price: #{problems.first(5).join('; ')}#{more}"
      end

      def items(type)
        @items ||= @book.import_items.where(review_status: ACCEPTED).includes(:matched).to_a.group_by(&:item_type)
        @items.fetch(type.to_s, [])
      end

      def publish_variant_price(item, counts)
        p = item.payload
        series = p['plan_series'].presence || Keys.series(p['series'], p['plant'])
        variant = item.change_type == 'removed' && item.matched.is_a?(CatalogPlanVariant) ? item.matched :
                    CatalogPlanVariant.find_by(manufacturer_id: @mfr, series: series, model_number: p['model_number'])
        if item.change_type == 'removed'
          variant&.update!(status: 'discontinued')
          counts['variants_discontinued'] += 1
          return
        end

        name = p['plan_name'].presence || Keys.plan_name(p['model_name'], series, p['model_number'])
        plan = CatalogPlan.find_or_initialize_by(manufacturer_id: @mfr, series: series, slug: name.parameterize)
        plan.assign_attributes(name: name, factory_id: Plants.for_item(item, @book), status: 'active')
        plan.plan_code ||= Catalog::ModelNumber.parse(p['model_number']).plan_code
        plan.save!

        variant ||= CatalogPlanVariant.new(manufacturer_id: @mfr, series: series, model_number: p['model_number'])
        variant.assign_attributes(catalog_plan: plan, model_number_as_printed: p['model_number_as_printed'],
                                  width_ft: p['width_ft'], length_ft: p['length_ft'], beds: p['beds'],
                                  baths: p['baths'], home_type: p['home_type'], status: 'active',
                                  building_code: p['building_code'].presence_in(CatalogPlanVariant::BUILDING_CODES))
        variant.external_ids = variant.external_ids.merge(p['external']) if p['external'].is_a?(Hash)
        variant.save!

        CatalogVariantPrice.create!(price_book: @book, variant: variant, net_base_price: p['net_base_price'],
                                    required_adders: p['required_adders'] || [], total_base_price: p['total_base_price'],
                                    source_ref: item.source_ref)
        item.update_columns(matched_type: 'CatalogPlanVariant', matched_id: variant.id)
        counts['variant_prices'] += 1
      end

      def publish_option_price(item, coded, counts)
        p = item.payload
        group = group_for(p['section'])
        option = CatalogOption.find_or_initialize_by(manufacturer_id: @mfr, key: p['option_key'] || Keys.option(p['section'], p['description']))
        option.assign_attributes(
          group: group, name: p['description'].to_s.truncate(250), status: 'active',
          kind: kind_for(p), in_place_of: p['in_place_of'], package_items: Array(p['package_items']),
          metadata: option.metadata.merge('section' => p['section'], 'tab' => p['tab'])
        )
        option.factory_code ||= coded.find { |c| coded_match?(c.payload, p) }&.payload&.dig('factory_code')
        option.save!

        applies = p['applies_to'] || {}
        models = Array(applies['model_numbers']).presence || [Sections.model_number_in(p['section'])].compact
        variant_id = models.filter_map { |m| variant_for_option(m, p['tab']) }.first
        where = Applicability.resolve(name: p['description'], tab: p['tab'], series_list: series_list,
                                      model_specific: variant_id.present?, ai: applies)
        CatalogOptionPrice.create!(
          price_book: @book, option: option, dealer_cost: p['dealer_cost'], suggested_retail: p['suggested_retail'],
          is_standard: p['is_standard'] == true, catalog_plan_variant_id: variant_id, **where.symbolize_keys,
          construction: applies['construction'].presence_in(CatalogOptionPrice::CONSTRUCTIONS),
          building_code: applies['building_code'].presence_in(CatalogPlanVariant::BUILDING_CODES),
          source_ref: item.source_ref
        )
        item.update_columns(matched_type: 'CatalogOption', matched_id: option.id)
        counts['option_prices'] += 1
      end

      def series_list
        @series_list ||= CatalogPlan.where(manufacturer_id: @mfr).distinct.pluck(:series)
      end

      # A model-specific option names a model number; when two series share
      # that number, prefer the series the option's tab is for.
      def variant_for_option(model_number, tab)
        found = CatalogPlanVariant.where(manufacturer_id: @mfr, model_number: Catalog::ModelNumber.normalize(model_number)).to_a
        return found.first&.id if found.size <= 1

        (found.find { |v| v.series.present? && tab.to_s.downcase.include?(v.series.downcase) } || found.first).id
      end

      # A coded master-list option already priced through an order form gets
      # its code there; one no order form mentions becomes its own option.
      def publish_coded_option(item, counts)
        p = item.payload
        return if CatalogOption.exists?(manufacturer_id: @mfr, factory_code: p['factory_code'])

        option = CatalogOption.find_or_initialize_by(manufacturer_id: @mfr, key: "coded--#{p['factory_code'].to_s.parameterize}")
        option.assign_attributes(group: group_for('Other options'), name: p['description'].to_s.truncate(250),
                                 factory_code: p['factory_code'], kind: 'upgrade', status: 'active')
        option.save!
        where = Applicability.resolve(name: p['description'], tab: nil, series_list: series_list)
        CatalogOptionPrice.create!(price_book: @book, option: option, dealer_cost: p['dealer_cost'],
                                   suggested_retail: p['suggested_retail'], source_ref: item.source_ref, **where.symbolize_keys)
        counts['coded_options'] += 1
      end

      def publish_color(item, counts)
        p = item.payload
        group = group_for(p['group'].presence || 'Colors')
        option = CatalogOption.find_or_initialize_by(manufacturer_id: @mfr, key: Keys.option(p['group'], p['name']))
        option.assign_attributes(group: group, name: p['name'].to_s.truncate(250), kind: 'color', status: 'active',
                                 metadata: option.metadata.merge('color_set' => ColorSets.normalize(p['group'])))
        option.save!
        CatalogOptionPrice.create!(price_book: @book, option: option, is_standard: true, source_ref: item.source_ref,
                                   series: Applicability.series_for(p['tab'].to_s, series_list))
        counts['colors'] += 1
      end

      def publish_standard(item, counts)
        p = item.payload
        @book.standard_features.create!(series: p['series'], building_code: p['building_code'],
                                        category: p['category'], name: p['name'], position: p['position'].to_i)
        counts['standard_features'] += 1
      end

      def group_for(section)
        @groups ||= {}
        key, name = Sections.group_for(section)
        @groups[key] ||= CatalogOptionGroup.find_or_initialize_by(manufacturer_id: @mfr, factory_id: @book.factory_id,
                                                                  series: nil, key: key).tap do |g|
          g.name = name
          g.selection_type ||= 'multiple'
          g.position = Sections::GROUPS.index { |k, _, _| k == key } || Sections::GROUPS.size
          g.save!
        end
      end

      def kind_for(p)
        return 'package' if Array(p['package_items']).any?
        return 'swap' if p['in_place_of'].present?
        return 'standard' if p['is_standard'] == true

        'upgrade'
      end

      # Same cost and mostly the same words (the Phase 0 matching rule).
      def coded_match?(coded, p)
        return false unless coded['dealer_cost'].to_f.positive? && coded['dealer_cost'].to_f == p['dealer_cost'].to_f

        a = words(coded['description'])
        b = words(p['description'])
        (a & b).size.to_f / [(a | b).size, 1].max >= 0.4
      end

      def words(s) = s.to_s.downcase.gsub(/[^a-z0-9 ]/, ' ').split.reject { |t| t.size < 2 }.to_set

      # Inventory rows whose factory model the catalog knows: by Champion model
      # id (reaches any dealer's feed, including later ones) and by the exact
      # homes a loaded-catalog match named.
      def link_inventory
        variants = CatalogPlanVariant.where(manufacturer_id: @mfr).where("external_ids ?| array['champion_model_id','vehicle_ids']").to_a
        InventoryLinker.link_all(variants.filter_map { |v| v.external_ids['champion_model_id'].presence }.uniq)
        variants.each do |v|
          ids = Array(v.external_ids['vehicle_ids'])
          Vehicle.where(id: ids, catalog_plan_variant_id: nil).update_all(catalog_plan_variant_id: v.id) if ids.any?
        end
      end
    end
  end
end
