# frozen_string_literal: true

# TrueBuild price books: platform admins import a factory's price package once
# and every dealer subscribed to that manufacturer prices from it. Platform
# data, so there is no set_company_scope and company_id is never a param.
#
# Flow: create a book for a manufacturer (and plant), upload the files (loose
# or a ZIP), extract, review the items (flags and changes first), publish.
class Api::Admin::CatalogPriceBooksController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_book, except: %i[index create factories]
  before_action :require_editable, only: %i[upload extract update_item bulk_review link_catalog retry_document auto_resolve
                                            update_tabs]

  ITEM_SORT = "CASE change_type WHEN 'removed' THEN 0 WHEN 'changed' THEN 1 WHEN 'new' THEN 2 ELSE 3 END, " \
              'jsonb_array_length(flags) DESC, id'

  # GET /api/admin/catalog_price_books
  def index
    books = CatalogPriceBook.includes(:manufacturer, :factory).order(created_at: :desc)
    books = books.where(manufacturer_id: params[:manufacturer_id]) if params[:manufacturer_id].present?
    books = books.where(status: params[:status]) if params[:status].present?
    render json: { items: books.limit(200).map { |b| book_json(b) } }
  end

  # GET /api/admin/catalog_price_books/:id
  def show
    render json: book_json(@book, detailed: true)
  end

  # POST /api/admin/catalog_price_books
  def create
    manufacturer = Manufacturer.where(company_id: nil).find_by(id: params[:manufacturer_id])
    return render json: { error: 'Choose a platform manufacturer' }, status: :unprocessable_entity unless manufacturer

    factory = find_or_create_factory(manufacturer)
    return if performed?

    book = CatalogPriceBook.new(manufacturer: manufacturer, factory: factory, created_by: original_user,
                                name: params[:name].presence || default_name(manufacturer, factory),
                                effective_on: params[:effective_on].presence, notes: params[:notes])
    if book.save
      render json: book_json(book, detailed: true), status: :created
    else
      render json: { errors: book.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/admin/catalog_price_books/:id
  def update
    return render json: { error: 'A published book cannot be edited' }, status: :unprocessable_entity unless @book.editable?

    if @book.update(params.permit(:name, :effective_on, :notes))
      render json: book_json(@book, detailed: true)
    else
      render json: { errors: @book.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/admin/catalog_price_books/:id
  def destroy
    unless @book.editable? || @book.status == 'rejected'
      return render json: { error: 'A published book cannot be deleted' }, status: :unprocessable_entity
    end

    @book.documents.each { |d| PrivateFiles.delete(PrivateFiles.ref(d.storage_key, d.storage_bucket)) if d.storage_key }
    @book.destroy!
    head :no_content
  end

  # POST /api/admin/catalog_price_books/:id/upload   (files[] or file; ZIPs are unpacked)
  def upload
    files = Array(params[:files]).presence || Array(params[:file])
    return render json: { error: 'No files provided' }, status: :unprocessable_entity if files.empty?

    result = Catalog::PriceBooks::Ingest.new(@book).call(files)
    render json: {
      added: result.added.map { |d| document_json(d) },
      duplicates: result.duplicates.map(&:filename),
      skipped: result.skipped,
      book: book_json(@book.reload, detailed: true)
    }, status: :created
  rescue PrivateFiles::NotConfigured => e
    render json: { error: e.message }, status: :service_unavailable
  end

  # POST /api/admin/catalog_price_books/:id/extract   (all=true re-reads every file)
  def extract
    docs = @book.documents.where.not(kind: 'image')
    docs = docs.where(extraction_status: %w[pending failed]) unless params[:all].to_s == 'true'
    return render json: { error: 'No files waiting to be read' }, status: :unprocessable_entity if docs.none?

    @book.update!(status: 'extracting')
    queued = 0
    docs.find_each do |d|
      # A second click (or a second admin) must not read the same file again.
      d.with_lock do
        next if recently_queued?(d)

        d.update!(extraction_status: 'pending', extraction_error: nil,
                  metadata: d.metadata.merge('queued_at' => Time.current.iso8601))
        CatalogPriceBookExtractionJob.perform_later(d.id)
        queued += 1
      end
    end
    render json: book_json(@book.reload, detailed: true).merge(queued: queued), status: :accepted
  end

  # POST /api/admin/catalog_price_books/:id/documents/:document_id/retry
  def retry_document
    doc = @book.documents.find(params[:document_id])
    doc.with_lock do
      if doc.extraction_status == 'running' || recently_queued?(doc)
        return render json: { error: 'This file is already being read' }, status: :conflict
      end

      @book.update!(status: 'extracting')
      doc.update!(extraction_status: 'pending', extraction_error: nil,
                  metadata: doc.metadata.merge('queued_at' => Time.current.iso8601))
      CatalogPriceBookExtractionJob.perform_later(doc.id)
    end
    render json: document_json(doc), status: :accepted
  end

  # GET /api/admin/catalog_price_books/:id/documents/:document_id/download
  def download_document
    doc = @book.documents.find(params[:document_id])
    url = PrivateFiles.url(PrivateFiles.ref(doc.storage_key, doc.storage_bucket), expires_in: 10.minutes,
                           filename: doc.filename, disposition: params[:inline] == 'true' ? 'inline' : 'attachment')
    render json: { url: url, filename: doc.filename }
  end

  # GET /api/admin/catalog_price_books/:id/documents/:document_id/tabs
  # A workbook's tabs with rows, year and estimated cost, and which are ticked.
  def tabs
    doc = @book.documents.find(params[:document_id])
    unless doc.metadata['tab_list']
      return render json: { error: 'Only workbooks have tabs' }, status: :unprocessable_entity unless doc.kind == 'order_form'

      bytes = PrivateFiles.read(PrivateFiles.ref(doc.storage_key, doc.storage_bucket))
      list = Catalog::PriceBooks::TabInventory.for_bytes(doc.filename, bytes)
      doc.update!(metadata: doc.metadata.merge('tab_list' => list,
                                               'selected_tabs' => doc.metadata['selected_tabs'] ||
                                                                  Catalog::PriceBooks::TabInventory.default_selection(list)))
    end
    render json: tabs_json(doc)
  end

  # PATCH /api/admin/catalog_price_books/:id/documents/:document_id/tabs   { selected_tabs: [...] }
  def update_tabs
    doc = @book.documents.find(params[:document_id])
    names = Array(doc.metadata['tab_list']).map { |t| t['name'] }
    chosen = Array(params[:selected_tabs]).map(&:to_s)
    unknown = chosen - names
    return render json: { error: "Unknown tabs: #{unknown.join(', ')}" }, status: :unprocessable_entity if unknown.any?

    doc.update!(metadata: doc.metadata.merge('selected_tabs' => chosen))
    render json: tabs_json(doc)
  end

  # GET /api/admin/catalog_price_books/:id/items
  def items
    scope = @book.import_items.includes(:document)
    scope = scope.where(item_type: params[:item_type]) if params[:item_type].present?
    scope = scope.where(review_status: params[:review_status]) if params[:review_status].present?
    scope = scope.where(change_type: params[:change_type]) if params[:change_type].present?
    scope = scope.where(catalog_price_book_document_id: params[:document_id]) if params[:document_id].present?
    scope = scope.where("source_ref->>'sheet' = ?", params[:sheet]) if params[:sheet].present?
    scope = scope.flagged if params[:flagged].to_s == 'true'
    scope = scope.where("jsonb_array_length(flags) = 0") if params[:flagged].to_s == 'false'
    scope = scope.where('flags ? :f', f: params[:flag]) if params[:flag].present?
    if params[:search].present?
      scope = scope.where('payload::text ILIKE ?', "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%")
    end

    total = scope.count
    page = [params[:page].to_i, 1].max
    per_page = [(params[:per_page] || 50).to_i, 200].min
    rows = scope.order(Arel.sql(ITEM_SORT)).offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: rows.map { |i| item_json(i) },
      meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil,
              counts: review_counts }
    }
  end

  # PATCH /api/admin/catalog_price_books/:id/items/:item_id
  # { review_status: approved|rejected|pending, payload: { ...fields to change } }
  def update_item
    item = @book.import_items.find(params[:item_id])
    status = params[:review_status].presence
    if status && !%w[approved rejected pending].include?(status)
      return render json: { error: 'review_status must be approved, rejected or pending' }, status: :unprocessable_entity
    end

    edits = params[:payload].respond_to?(:to_unsafe_h) ? params[:payload].to_unsafe_h.deep_stringify_keys : {}
    attrs = {}
    if edits.any?
      attrs[:payload] = item.payload.merge(edits)
      attrs[:review_status] = status == 'rejected' ? 'rejected' : 'edited'
    elsif status
      attrs[:review_status] = status
    end
    attrs.merge!(reviewed_by: original_user, reviewed_at: Time.current) unless attrs[:review_status] == 'pending'
    item.update!(attrs)
    render json: item_json(item)
  end

  # POST /api/admin/catalog_price_books/:id/bulk_review
  # { review_status:, ids: [...] } or { review_status:, unflagged: true, item_type: }
  def bulk_review
    status = params[:review_status]
    unless %w[approved rejected pending].include?(status)
      return render json: { error: 'review_status must be approved, rejected or pending' }, status: :unprocessable_entity
    end

    scope = @book.import_items
    if params[:ids].present?
      scope = scope.where(id: Array(params[:ids]))
    elsif params[:sheet].present?
      # Everything read from one workbook tab, e.g. rejecting a 2022 copy.
      scope = scope.where("source_ref->>'sheet' = ?", params[:sheet])
      scope = scope.where(catalog_price_book_document_id: params[:document_id]) if params[:document_id].present?
    elsif params[:unflagged].to_s == 'true'
      # The common case: approve everything no check objected to, then read the rest.
      scope = scope.pending.where('jsonb_array_length(flags) = 0')
      scope = scope.where(item_type: params[:item_type]) if params[:item_type].present?
    else
      return render json: { error: 'Pass ids, sheet, or unflagged: true' }, status: :unprocessable_entity
    end

    reviewer = status == 'pending' ? { reviewed_by_id: nil, reviewed_at: nil } : { reviewed_by_id: original_user.id, reviewed_at: Time.current }
    updated = scope.update_all(reviewer.merge(review_status: status, updated_at: Time.current))
    render json: { updated: updated, counts: review_counts }
  end

  # POST /api/admin/catalog_price_books/:id/auto_resolve
  # Approves what needs no decision, fixes known patterns (with the reason on
  # the item), reads uncertain rows a second time, and leaves only real
  # decisions pending.
  def auto_resolve
    verifier = Catalog::PriceBooks::SecondReader.new(@book)
    result = Catalog::PriceBooks::AutoResolver.new(@book, by: original_user, verifier: verifier).call
    render json: { approved: result.approved, corrected: result.corrected, needs_you: result.needs_you,
                   reasons: result.reasons, counts: review_counts }
  end

  # GET /api/admin/catalog_price_books/factories?manufacturer_id=
  # The manufacturer's plants, so a new package lands on the plant it replaces.
  def factories
    manufacturer = Manufacturer.where(company_id: nil).find_by(id: params[:manufacturer_id])
    return render json: { items: [] } unless manufacturer

    counts = CatalogPriceBook.where(manufacturer: manufacturer).group(:factory_id).count
    items = manufacturer.factories.order(:name).map do |f|
      { id: f.id, name: f.name, city: f.city, state: f.state, price_books: counts[f.id].to_i }
    end
    render json: { items: items }
  end

  # GET /api/admin/catalog_price_books/:id/link_sources
  def link_sources
    render json: { loaded: Catalog::PriceBooks::LinkSources.loaded,
                   champion_brands: Catalog::PriceBooks::LinkSources.champion_brands,
                   links: @book.metadata['catalog_links'] || [] }
  end

  # POST /api/admin/catalog_price_books/:id/link_catalog
  #   { source: 'loaded', key: 'ims:5' }  or  { source: 'champion_site', brand_slug:, location: }
  def link_catalog
    models, label =
      case params[:source]
      when 'loaded'
        row = Catalog::PriceBooks::LinkSources.loaded.find { |r| r[:key] == params[:key] }
        return render json: { error: 'Choose one of the loaded catalogs' }, status: :unprocessable_entity unless row

        [Catalog::PriceBooks::LinkSources.loaded_models(row[:key]), row[:label]]
      when 'champion_site'
        brand = params[:brand_slug].presence
        location = params[:location].presence || [@book.factory&.city, @book.factory&.state].compact.join(', ').presence
        unless brand && location
          return render json: { error: 'Choose a brand, and a place to search near (e.g. "Topeka, IN")' }, status: :unprocessable_entity
        end

        [Catalog::PriceBooks::LinkSources.champion_models(brand_slug: brand, location: location), "Champion catalog: #{brand}"]
      else
        return render json: { error: 'source must be loaded or champion_site' }, status: :unprocessable_entity
      end

    render json: Catalog::PriceBooks::CatalogLink.new(@book, models: models, label: label).call
  rescue Catalog::PriceBooks::ExtractionError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    render json: { error: "Could not read that catalog: #{e.message}" }, status: :bad_gateway
  end

  # POST /api/admin/catalog_price_books/:id/publish
  def publish
    counts = Catalog::PriceBooks::Publisher.new(@book, by: original_user).call
    render json: { published: true, counts: counts, book: book_json(@book.reload, detailed: true) }
  rescue Catalog::PriceBooks::Publisher::NotReady, ActiveRecord::RecordInvalid, ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_book
    @book = CatalogPriceBook.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  # Queued in the last 15 minutes and not started yet.
  def recently_queued?(doc)
    at = doc.metadata['queued_at'].presence&.then { |t| Time.zone.parse(t) rescue nil }
    doc.extraction_status == 'pending' && at && at > 15.minutes.ago
  end

  def require_editable
    return if @book.editable?

    render json: { error: "This price book is #{@book.status} and can no longer change" }, status: :unprocessable_entity
  end

  def find_or_create_factory(manufacturer)
    if params[:factory_id].present?
      factory = manufacturer.factories.find_by(id: params[:factory_id])
      render json: { error: 'That plant belongs to another manufacturer' }, status: :unprocessable_entity unless factory
      factory
    elsif params[:factory_name].present?
      name = params[:factory_name].to_s.strip
      manufacturer.factories.find_or_create_by!(code: name.parameterize.upcase.first(20)) do |f|
        f.name = name
        f.city = params[:factory_city]
        f.state = params[:factory_state]
      end
    end
  end

  def default_name(manufacturer, factory)
    [manufacturer.name, factory&.name, Date.current.year].compact.join(' ')
  end

  def review_counts(book = @book)
    items = book.import_items
    {
      total: items.count,
      pending: items.pending.count,
      flagged_pending: items.pending.flagged.count,
      by_status: items.group(:review_status).count,
      by_type: items.group(:item_type).count
    }
  end

  def book_json(book, detailed: false)
    data = {
      id: book.id, name: book.name, status: book.status, effective_on: book.effective_on,
      manufacturer: { id: book.manufacturer_id, name: book.manufacturer&.name },
      factory: book.factory && { id: book.factory_id, name: book.factory.name, city: book.factory.city, state: book.factory.state },
      published_at: book.published_at, created_at: book.created_at, updated_at: book.updated_at,
      summary: book.metadata['summary'], published_counts: book.metadata['published_counts']
    }
    return data unless detailed

    data.merge(
      notes: book.notes, supersedes_id: book.supersedes_id, compared_with: book.metadata['compared_with'],
      catalog_links: book.metadata['catalog_links'] || [],
      auto_resolve: book.metadata['auto_resolve'],
      cost: {
        spent_usd: Catalog::PriceBooks::Recorder.spent_usd(book).round(2),
        budget_usd: Catalog::PriceBooks::Recorder.budget_usd,
        estimate_waiting_usd: Catalog::PriceBooks::CostEstimate.for_documents(
          book.documents.select { |d| %w[pending failed].include?(d.extraction_status) && d.kind != 'image' }
        )
      },
      documents: book.documents.order(:created_at).map { |d| document_json(d) },
      review: review_counts(book)
    )
  end

  def tabs_json(doc)
    selected = Array(doc.metadata['selected_tabs'])
    items = @book.import_items.where(document: doc).group(Arel.sql("source_ref->>'sheet'")).count
    tabs = Array(doc.metadata['tab_list']).map { |t| t.merge('selected' => selected.include?(t['name']), 'items' => items[t['name']].to_i) }
    { document_id: doc.id, tabs: tabs, selected_tabs: selected,
      estimate_usd: Catalog::PriceBooks::CostEstimate.for_document(doc).round(2) }
  end

  def document_json(doc)
    usage = doc.metadata['usage'] || {}
    {
      id: doc.id, filename: doc.filename, kind: doc.kind, content_type: doc.content_type, byte_size: doc.byte_size,
      page_count: doc.page_count, extraction_status: doc.extraction_status, extraction_error: doc.extraction_error,
      extracted_at: doc.extracted_at, archive_path: doc.metadata['archive_path'],
      scanned: doc.metadata['scanned'], missing_model_numbers: doc.metadata['missing_model_numbers'],
      tabs: doc.metadata['tabs'], usage: usage.presence,
      estimate_usd: Catalog::PriceBooks::CostEstimate.for_document(doc).round(2),
      item_count: doc.import_items.size
    }
  end

  def item_json(item)
    {
      id: item.id, item_type: item.item_type, payload: item.payload, source_ref: item.source_ref,
      flags: item.flags, change_type: item.change_type, previous_values: item.previous_values,
      review_status: item.review_status, reviewed_at: item.reviewed_at,
      matched: item.matched_type && { type: item.matched_type, id: item.matched_id },
      document: item.document && { id: item.document.id, filename: item.document.filename }
    }
  end
end
