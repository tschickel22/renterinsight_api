# frozen_string_literal: true

module Catalog
  # A factory's line loaded without prices: its models, finishes and decor
  # samples, so buyers design its homes and ask the dealer for the price.
  # Timber Creek (2026-10-18) sent a model sheet, an order form and a finishes
  # guide but no upgrade prices, and many factories will be the same.
  #
  # Read from a spec (a hash, as JSON) that names everything, so it is read
  # once by a person or a Claude Code session, not by the API. Loading it again
  # updates what it names and adds what is new; nothing is removed.
  #
  #   manufacturer: { name:, code: }
  #   factory: { name:, code:, city:, state: }
  #   book: { name: }
  #   groups: [{ key:, name:, position:, sets: [{ name:, options: [{ name:, standard:, swatch: { image_url:, hex:, page: } }] }] }]
  #   models: [{ number:, name:, series:, width_ft:, length_ft:, beds:, baths:, square_feet:, names: [], media: {} }]
  #
  # A finish not marked standard is an upgrade with no price (price on request).
  class UnpricedLine
    def self.load!(spec) = new(spec.deep_stringify_keys).load!

    def initialize(spec)
      @spec = spec
    end

    # => { manufacturer:, factory:, book:, options:, swatches:, models: } counts and records.
    def load!
      ActiveRecord::Base.transaction do
        @mfr = manufacturer
        @factory = factory
        @book = book
        options = @spec['groups'].to_a.sum { |g| load_group(g) }
        models = @spec['models'].to_a.map { |m| load_model(m) }
        { manufacturer: @mfr, factory: @factory, book: @book, options: options, swatches: @swatches.to_i, models: models.size }
      end
    end

    private

    def manufacturer
      m = @spec['manufacturer']
      Manufacturer.global.where('lower(name) = ?', m['name'].downcase).first ||
        Manufacturer.create!(name: m['name'], code: m['code'], industry_type: 'manufactured_home', active: true)
    end

    def factory
      f = @spec['factory']
      row = @mfr.factories.find_or_initialize_by(code: f['code'])
      row.update!(name: f['name'], city: f['city'], state: f['state'], is_active: true)
      row
    end

    # Published at once: it carries no prices to review, only what a buyer
    # can choose. A later priced book for the plant supersedes it.
    def book
      b = @spec['book']
      row = CatalogPriceBook.find_or_initialize_by(manufacturer: @mfr, factory: @factory, name: b['name'])
      row.status = 'published' if row.new_record?
      row.published_at ||= Time.current
      row.metadata = row.metadata.to_h.merge('unpriced' => true, 'loaded_by' => 'Catalog::UnpricedLine')
      row.save!
      row
    end

    def load_group(spec)
      group = CatalogOptionGroup.find_or_initialize_by(manufacturer: @mfr, factory: @factory, key: spec['key'])
      group.update!(name: spec['name'], position: spec['position'] || 0, selection_type: 'multiple')
      spec['sets'].to_a.sum do |set|
        set['options'].to_a.each { |o| load_option(group, set['name'], o) }.size
      end
    end

    def load_option(group, set_name, spec)
      key = "#{group.key}--#{set_name}-#{spec['name']}".parameterize
      option = CatalogOption.find_or_initialize_by(manufacturer: @mfr, key: key)
      option.update!(group: group, name: spec['name'], kind: 'color', status: 'active',
                     metadata: option.metadata.to_h.merge('color_set' => set_name))
      price = CatalogOptionPrice.find_or_initialize_by(price_book: @book, option: option, catalog_plan_variant_id: nil)
      standard = spec['standard'] == true
      price.update!(is_standard: standard, dealer_cost: nil,
                    source_ref: price.source_ref.to_h.merge('price_on_request' => !standard, 'loaded_by' => 'Catalog::UnpricedLine'))
      load_swatch(set_name, spec['name'], spec['swatch']) if spec['swatch'].present?
      option
    end

    def load_swatch(set_name, name, spec)
      swatch = CatalogSwatch.where(manufacturer: @mfr, factory: @factory)
                            .where('lower(set_name) = ? AND lower(name) = ?', set_name.downcase, name.downcase)
                            .first_or_initialize(set_name: set_name, name: name)
      swatch.update!(image_url: stored(spec['image_url']), hex: spec['hex'], page: spec['page'], note: spec['note'])
      @swatches = @swatches.to_i + 1
    end

    # A sample cropped in the session comes inline (data:image/jpeg;base64,...)
    # and is stored where the decor sheet reader stores its swatches.
    def stored(url)
      return url unless url.to_s.start_with?('data:')

      bytes = Base64.decode64(url.split(',', 2).last.to_s)
      s3 = S3UploadService.new
      key = "truebuild/swatches/#{@mfr.id}/#{Digest::SHA256.hexdigest(bytes)[0, 20]}.jpg"
      s3.s3_client.put_object(bucket: s3.bucket_name, key: key, body: bytes, content_type: 'image/jpeg')
      "https://#{s3.bucket_name}.s3.#{s3.region}.amazonaws.com/#{key}"
    end

    def load_model(spec)
      plan = CatalogPlan.find_or_initialize_by(manufacturer: @mfr, series: spec['series'], slug: spec['name'].parameterize)
      plan.update!(name: spec['name'], factory: @factory, status: 'active')
      variant = CatalogPlanVariant.find_or_initialize_by(manufacturer: @mfr, series: spec['series'],
                                                         model_number: Catalog::ModelNumber.normalize(spec['number']))
      media = spec['media'].present? ? variant.media_from_feed(spec['media']) : variant.media
      variant.update!(catalog_plan: plan, building_code: spec['building_code'] || 'HUD', status: 'active',
                      width_ft: spec['width_ft'], length_ft: spec['length_ft'], beds: spec['beds'], baths: spec['baths'],
                      square_feet: spec['square_feet'], media: media,
                      external_ids: variant.external_ids.to_h.merge('unpriced' => true, 'names' => Array(spec['names'])))
      variant
    end
  end
end
