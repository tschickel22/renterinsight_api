# frozen_string_literal: true

# Factory decor sheets and the finish samples read from them. Platform
# admins only; platform data, so no company scope.
class Api::Admin::CatalogSwatchesController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_manufacturer, only: %i[index upload color_checks]
  before_action :set_swatch, only: %i[update destroy]

  MAX_BYTES = 40.megabytes
  TYPES = %w[.pdf .png .jpg .jpeg .webp].freeze

  # GET /api/admin/catalog_swatches?manufacturer_id=
  def index
    sheets = CatalogSwatchSheet.where(manufacturer: @manufacturer).includes(:factory).order(created_at: :desc).limit(50)
    swatches = CatalogSwatch.where(manufacturer: @manufacturer).includes(:factory).order(:set_name, :name)
    render json: { sheets: sheets.map { |s| sheet_json(s) }, swatches: swatches.map { |s| swatch_json(s) } }
  end

  # POST /api/admin/catalog_swatches/upload (multipart: file, manufacturer_id, factory_id)
  def upload
    file = params[:file]
    return render json: { error: 'Choose a file' }, status: :unprocessable_entity unless file.respond_to?(:read)

    name = File.basename(file.original_filename.to_s)
    unless TYPES.include?(File.extname(name).downcase)
      return render json: { error: 'Upload a PDF or an image of the decor sheet' }, status: :unprocessable_entity
    end
    return render json: { error: 'That file is over 40 MB' }, status: :unprocessable_entity if file.size > MAX_BYTES

    factory = params[:factory_id].present? ? @manufacturer.factories.find_by(id: params[:factory_id]) : nil
    bytes = file.read
    key = "catalog/swatch-sheets/#{@manufacturer.id}/#{Digest::SHA256.hexdigest(bytes)[0, 12]}_#{name.gsub(/[^\w.\-]+/, '_')}"
    ref = PrivateFiles.put(bytes, key: key, content_type: file.content_type.presence || 'application/octet-stream')
    sheet = CatalogSwatchSheet.create!(manufacturer: @manufacturer, factory: factory, filename: name, storage_ref: ref)
    CatalogSwatchSheetJob.perform_later(sheet.id)
    render json: sheet_json(sheet), status: :created
  end

  # GET /api/admin/catalog_swatches/color_checks?manufacturer_id=
  # Every color a buyer can pick for this manufacturer and the dot they see:
  # from a decor sample, guessed from the name, or none. Lists the ones to
  # look at: a name and dot that disagree, no dot at all, or a guess the
  # sample shows was far off (the sample is used now).
  def color_checks
    pool = CatalogSwatch.where(manufacturer: @manufacturer).to_a
    colors = CatalogOption.where(manufacturer: @manufacturer, status: 'active', kind: 'color')
                          .pluck(:name, Arel.sql("metadata->>'color_set'")).map { |n, set| [set.presence || 'Colors', n] }
    named = CatalogOption.where(manufacturer: @manufacturer, status: 'active').where.not(kind: 'color')
                         .where("name ~ '^[A-Za-z0-9][A-Za-z0-9 ]{2,30}:'").pluck(:name)
                         .filter_map { |n| (m = n.match(Truebuild::BuyerCatalog::NAMED_CHOICE)) && [m[1].strip, m[2].strip] }
    items = (colors + named).uniq { |set, n| [set.downcase, n.downcase] }.map do |set, name|
      sample = CatalogSwatch.for_finish(manufacturer_id: @manufacturer.id, factory_id: nil, surface: set, value: name, pool: pool)
      guess = Truebuild::ColorSwatches.hex(name)
      hex = sample&.hex || guess
      note = if hex.nil?
               'has no dot: no decor sample matches and the name gives no color'
             elsif (problem = Truebuild::ColorCheck.problem(name, hex))
               problem
             elsif sample && guess && far_apart?(guess, sample.hex)
               "was guessed #{guess} from its name; the decor sample is #{sample.hex}, which is used now"
             end
      { set: set, name: name, hex: hex, source: sample ? 'sample' : (guess ? 'guess' : 'none'), sample_url: sample&.image_url, note: note }
    end
    render json: { total: items.size, from_samples: items.count { |i| i[:source] == 'sample' },
                   items: items.select { |i| i[:note] }.sort_by { |i| [i[:source] == 'sample' ? 1 : 0, i[:set], i[:name]] } }
  end

  # PATCH /api/admin/catalog_swatches/:id { name, set_name }
  def update
    if @swatch.update(params.permit(:name, :set_name).to_h.transform_values { |v| v.to_s.strip })
      render json: swatch_json(@swatch)
    else
      render json: { error: @swatch.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    render json: { error: 'Another sample already has that set and name' }, status: :unprocessable_entity
  end

  # DELETE /api/admin/catalog_swatches/sheets/:id
  # The sheet and every sample it holds, so a sheet uploaded to the wrong
  # plant can be uploaded again.
  def destroy_sheet
    sheet = CatalogSwatchSheet.find_by(id: params[:id])
    return render json: { error: 'Not found' }, status: :not_found unless sheet

    CatalogSwatch.where(catalog_swatch_sheet_id: sheet.id).delete_all
    sheet.destroy!
    head :no_content
  end

  # DELETE /api/admin/catalog_swatches/:id
  def destroy
    @swatch.destroy!
    head :no_content
  end

  private

  def far_apart?(a, b)
    la = Truebuild::ColorCheck.lch(a)
    lb = Truebuild::ColorCheck.lch(b)
    (la[0] - lb[0]).abs > 25
  end

  def set_manufacturer
    @manufacturer = Manufacturer.where(company_id: nil).find_by(id: params[:manufacturer_id])
    render json: { error: 'Choose a platform manufacturer' }, status: :unprocessable_entity unless @manufacturer
  end

  def set_swatch
    @swatch = CatalogSwatch.find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @swatch
  end

  def sheet_json(s)
    { id: s.id, filename: s.filename, factory: s.factory && { id: s.factory.id, name: s.factory.name },
      status: s.status, error: s.error, swatch_count: s.swatch_count, missed: s.missed, cost_usd: s.cost_usd&.to_f,
      created_at: s.created_at }
  end

  def swatch_json(s)
    { id: s.id, set_name: s.set_name, name: s.name, note: s.note, hex: s.hex, image_url: s.image_url,
      factory: s.factory && { id: s.factory.id, name: s.factory.name }, sheet_id: s.catalog_swatch_sheet_id }
  end
end
