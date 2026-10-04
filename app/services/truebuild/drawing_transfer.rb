# frozen_string_literal: true

require 'net/http'

module Truebuild
  # Copies TrueBuild and TrueView work already paid for from one environment
  # to another (staging to production): the published price books with their
  # factories and models (BookTransfer), the factories' decor samples, the
  # photos chosen for each model, the surface outlines and the finished
  # drawings. Run by
  # script/truebuild_transfer.rb, which pages export on one side into import
  # on the other through the admin API.
  #
  # Ids differ between databases, so rows travel by what they are: a
  # manufacturer by name, a factory by code, a model by manufacturer, series
  # and model number. Files are copied into the receiving side's own bucket,
  # so it never depends on the other's. Importing twice changes nothing.
  #
  # A designer finds a drawing by its photo, finish and exact prompt, and the
  # prompt names the option as the price book words it and the factory's
  # sample for the finish. So the books go first, then samples and photo
  # choices, then outlines and drawings.
  module DrawingTransfer
    module_function

    # books first: the price books (BookTransfer), then what TrueView drew on them.
    KINDS = %w[books swatches photos masks renders].freeze
    ONE = { 'books' => 'book', 'swatches' => 'swatch', 'photos' => 'photo', 'masks' => 'mask', 'renders' => 'render' }.freeze
    PAGE = 100
    RENDER_STATUSES = %w[done skipped rejected].freeze
    PHOTO_KEYS = %w[trueview_photos trueview_auto hidden_photos].freeze

    # => { rows: [...], next_after: id or nil }
    def export(kind, after_id: 0, limit: PAGE)
      scope = case kind
              when 'books' then BookTransfer.scope.includes(:manufacturer, :factory)
              when 'swatches' then CatalogSwatch.includes(:manufacturer, :factory)
              when 'photos'
                CatalogPlanVariant.includes(:catalog_plan, :manufacturer)
                                  .where("media ?| array['trueview_photos', 'trueview_auto', 'hidden_photos']")
              when 'masks' then TruebuildSurfaceMask.where(status: 'done')
              when 'renders'
                TruebuildRender.includes(catalog_plan_variant: %i[catalog_plan manufacturer])
                               .where(purpose: 'layer', lab_run: nil, status: RENDER_STATUSES)
              else raise ArgumentError, "kind must be one of #{KINDS.join(', ')}"
              end
      rows = scope.where('id > ?', after_id.to_i).order(:id).limit(limit.to_i.clamp(1, 500)).to_a
      { rows: rows.map { |r| send("#{ONE[kind]}_row", r) }, next_after: rows.size == limit.to_i ? rows.last.id : nil }
    end

    def book_row(b) = BookTransfer.export(b)

    def import_book(row) = BookTransfer.import!(row)

    def swatch_row(s)
      { id: s.id, manufacturer: s.manufacturer&.name, factory_code: s.factory&.code,
        **s.attributes.slice('set_name', 'name', 'note', 'hex', 'image_url', 'page').symbolize_keys }
    end

    def photo_row(v)
      { id: v.id, **model_ref(v), media: v.media.slice(*PHOTO_KEYS) }
    end

    def mask_row(m)
      { id: m.id, **m.attributes.slice('source_url', 'surface', 'version', 'status', 'mask_url', 'coverage', 'model', 'error', 'usage').symbolize_keys }
    end

    def render_row(r)
      { id: r.id, model_ref: r.catalog_plan_variant && model_ref(r.catalog_plan_variant),
        **r.attributes.slice('room', 'source_url', 'selection', 'selection_key', 'model_key', 'provider', 'model', 'status',
                             'image_url', 'cost_usd', 'latency_ms', 'usage', 'prompt', 'error', 'purpose', 'layer_url',
                             'mask_coverage').symbolize_keys }
    end

    def model_ref(v)
      { manufacturer: v.manufacturer&.name, series: v.catalog_plan&.series, model_number: v.model_number }
    end

    # => { created:, updated:, skipped: [why...] }
    def import!(kind, rows)
      raise ArgumentError, "kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(kind)

      result = { created: 0, updated: 0, skipped: [] }
      Array(rows).each do |row|
        row = row.to_h.deep_stringify_keys
        outcome = send("import_#{ONE[kind]}", row)
        outcome.is_a?(String) ? result[:skipped] << "#{row['id']}: #{outcome}" : result[outcome] += 1
      rescue StandardError => e
        result[:skipped] << "#{row['id']}: #{e.class} #{e.message.first(150)}"
      end
      result
    end

    def import_swatch(row)
      manufacturer = Manufacturer.find_by(name: row['manufacturer']) or return "no manufacturer #{row['manufacturer']}"
      factory = row['factory_code'] && manufacturer.factories.find_by(code: row['factory_code'])
      return "no factory #{row['factory_code']}" if row['factory_code'] && !factory

      swatch = CatalogSwatch.find_or_initialize_by(manufacturer_id: manufacturer.id, factory_id: factory&.id,
                                                   set_name: row['set_name'], name: row['name'])
      created = swatch.new_record?
      swatch.assign_attributes(row.slice('note', 'hex', 'page'))
      swatch.image_url = rehost(row['image_url']) if created || swatch.image_url.blank?
      swatch.save!
      created ? :created : :updated
    end

    def import_photo(row)
      variant = find_variant(row) or return "no model #{row.values_at('manufacturer', 'model_number').join(' ')}"
      variant.update_columns(media: (variant.media || {}).merge(row['media'].slice(*PHOTO_KEYS)))
      :updated
    end

    def import_mask(row)
      mask = TruebuildSurfaceMask.find_or_initialize_by(source_url: row['source_url'], surface: row['surface'], version: row['version'])
      return :updated unless mask.new_record? # never overwrite an outline the receiving side made itself

      mask.assign_attributes(row.slice('status', 'coverage', 'model', 'error', 'usage'))
      mask.mask_url = rehost(row['mask_url'])
      mask.save!
      :created
    end

    def import_render(row)
      existing = TruebuildRender.where(source_url: row['source_url'], selection_key: row['selection_key'], model_key: row['model_key'],
                                       purpose: 'layer', prompt: row['prompt'])
      variant = row['model_ref'] && find_variant(row['model_ref'])
      if (found = existing.first)
        # Copied before this side had the model: link it now. A second run
        # after the price books are published finishes the job.
        found.update_columns(catalog_plan_variant_id: variant.id) if variant && found.catalog_plan_variant_id.nil?
        return :updated # the receiving side has this drawing (or drew its own)
      end

      attrs = row.slice('room', 'source_url', 'selection', 'selection_key', 'model_key', 'provider', 'model', 'status', 'cost_usd',
                        'latency_ms', 'prompt', 'error', 'purpose', 'mask_coverage')
      # Sample ids name the sending side's rows; the prompt already says
      # which sample each drawing used.
      usage = row['usage'].to_h.except('swatch_ids').merge('copied_from' => row['id'])
      TruebuildRender.create!(attrs.merge('catalog_plan_variant_id' => variant&.id, 'usage' => usage,
                                          'image_url' => rehost(row['image_url']), 'layer_url' => rehost(row['layer_url'])))
      :created
    end

    def find_variant(ref)
      manufacturer = Manufacturer.find_by(name: ref['manufacturer']) or return nil
      CatalogPlanVariant.joins(:catalog_plan).where(manufacturer_id: manufacturer.id, model_number: ref['model_number'])
                        .order(Arel.sql("CASE WHEN catalog_plans.series IS NOT DISTINCT FROM #{CatalogPlanVariant.connection.quote(ref['series'])} THEN 0 ELSE 1 END"))
                        .first
    end

    # A file from the sending side, stored in this side's bucket under the
    # same path. A file already in this bucket is left where it is.
    def rehost(url)
      return nil if url.blank?

      s3 = S3UploadService.new
      return url if url.include?("#{s3.bucket_name}.s3.")

      key = URI(url).path.delete_prefix('/')
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 60) { |h| h.get(uri.request_uri) }
      raise Trueview::Error, "Could not fetch #{url} (#{res.code})" unless res.is_a?(Net::HTTPSuccess)

      Trueview.store_bytes(res.body, res['content-type'].presence || 'application/octet-stream', key)
    end
  end
end
