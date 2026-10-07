# frozen_string_literal: true

# Correcting a price book's prices after it is published, and the dealers'
# correction requests (backlog E49 follow-up). Platform data: no company scope,
# and company_id is never a param.
#
#   GET   /api/admin/catalog_price_books/:id/prices?kind=base|option&search=&group=&page=
#   PATCH /api/admin/catalog_price_books/:id/prices/:kind/:price_id   { changes: { field: value }, reason?, request_id? }
#   GET   /api/admin/catalog_price_books/:id/corrections
#   GET   /api/admin/catalog_price_requests?status=open&book_id=
#   POST  /api/admin/catalog_price_requests/:id/apply     { value?, reason? }
#   POST  /api/admin/catalog_price_requests/:id/dismiss   { note? }
class Api::Admin::CatalogPriceCorrectionsController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_book, only: %i[prices update_price corrections]
  before_action :set_request, only: %i[apply dismiss]

  rescue_from Truebuild::PriceCorrector::Invalid do |e|
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def prices
    page = [params[:page].to_i, 1].max
    per_page = [(params[:per_page] || 100).to_i, 500].min
    corrected = @book.corrections.distinct.pluck(:target_type, :target_id).to_set
    if params[:kind] == 'option'
      scope = @book.option_prices.joins(option: :group).includes(:variant, option: :group)
      scope = scope.where(catalog_options: { catalog_option_group_id: params[:group] }) if params[:group].present?
      if params[:search].present?
        q = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
        scope = scope.where('catalog_options.name ILIKE :q OR catalog_options.factory_code ILIKE :q', q: q)
      end
      total = scope.count
      rows = scope.order('catalog_option_groups.position, catalog_option_groups.name, LOWER(catalog_options.name), catalog_option_prices.id')
                  .offset((page - 1) * per_page).limit(per_page)
                  .map { |op| option_row(op, corrected.include?(['CatalogOptionPrice', op.id])) }
      groups = CatalogOptionGroup.where(id: @book.option_prices.joins(:option).select('catalog_options.catalog_option_group_id'))
                                 .order(:position, :name).map { |g| { id: g.id, name: g.name } }
    else
      scope = @book.variant_prices.joins(variant: :catalog_plan).includes(variant: :catalog_plan)
      if params[:search].present?
        q = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
        scope = scope.where('catalog_plan_variants.model_number ILIKE :q OR catalog_plans.name ILIKE :q OR catalog_plans.series ILIKE :q', q: q)
      end
      total = scope.count
      rows = scope.order('catalog_plans.series, catalog_plans.name, catalog_plan_variants.model_number')
                  .offset((page - 1) * per_page).limit(per_page)
                  .map { |vp| base_row(vp, corrected.include?(['CatalogVariantPrice', vp.id])) }
      groups = []
    end
    render json: { rows: rows, groups: groups, open_requests: @book.price_requests.open.count,
                   meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil } }
  end

  def update_price
    target = (params[:kind] == 'option' ? @book.option_prices : @book.variant_prices).find_by(id: params[:price_id])
    return render json: { error: 'Not found' }, status: :not_found unless target

    price_request = params[:request_id].present? ? @book.price_requests.find_by(id: params[:request_id]) : nil
    changes = params[:changes].respond_to?(:to_unsafe_h) ? params[:changes].to_unsafe_h : {}
    log = Truebuild::PriceCorrector.new(book: @book, user: original_user).apply(target, changes, reason: params[:reason], request: price_request)
    resolve!(price_request, 'applied', params[:reason]) if price_request&.status == 'open' && log.any?
    target.reload
    render json: { row: target.is_a?(CatalogOptionPrice) ? option_row(target, true) : base_row(target, true), changed: log }
  end

  def corrections
    rows = @book.corrections.includes(:corrected_by).order(created_at: :desc).limit(200).to_a
    labels = target_labels(rows)
    render json: { corrections: rows.map { |c|
      { id: c.id, target_type: c.target_type, target_id: c.target_id, label: labels[[c.target_type, c.target_id]],
        field: c.field, old_value: c.old_value, new_value: c.new_value, reason: c.reason,
        corrected_by: c.corrected_by&.name, request_id: c.catalog_price_request_id, at: c.created_at }
    } }
  end

  def requests
    scope = CatalogPriceRequest.includes(:company, :price_book, :requested_by).order(created_at: :desc)
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(catalog_price_book_id: params[:book_id]) if params[:book_id].present?
    render json: { requests: scope.limit(200).map { |r| request_json(r) } }
  end

  # Applies the dealer's figure (or the admin's) to the book.
  def apply
    return render json: { error: "This request is #{@price_request.status}" }, status: :unprocessable_entity unless @price_request.status == 'open'

    target = @price_request.target
    return render json: { error: 'That price is no longer in the book' }, status: :unprocessable_entity unless target

    value = params.key?(:value) ? params[:value] : @price_request.suggested_value
    reason = params[:reason].presence || "Reported by #{@price_request.company.name}#{@price_request.note.present? ? ": #{@price_request.note}" : ''}"
    Truebuild::PriceCorrector.new(book: @price_request.price_book, user: original_user)
                             .apply(target, { @price_request.book_field => value }, reason: reason, request: @price_request)
    resolve!(@price_request, 'applied', params[:reason])
    render json: { request: request_json(@price_request.reload) }
  end

  def dismiss
    return render json: { error: "This request is #{@price_request.status}" }, status: :unprocessable_entity unless @price_request.status == 'open'

    resolve!(@price_request, 'dismissed', params[:note])
    render json: { request: request_json(@price_request.reload) }
  end

  private

  def set_book
    @book = CatalogPriceBook.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  def set_request
    @price_request = CatalogPriceRequest.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  # Closes the request and tells the dealer who sent it.
  def resolve!(price_request, status, note)
    price_request.update!(status: status, resolved_by: original_user, resolved_at: Time.current, resolution_note: note.presence)
    notify_dealer(price_request, status, note)
  end

  # Best-effort: the request is already closed either way.
  def notify_dealer(price_request, status, note)
    return unless price_request.requested_by

    applied = status == 'applied'
    NotificationService.create(
      recipient: price_request.requested_by, notification_type: :truebuild_price_request, notifiable: price_request,
      company_id: price_request.company_id, title: applied ? 'Price book corrected' : 'Price book left as is',
      message: applied ? "#{price_request.label}: the price book now has the corrected figure." :
                         "#{price_request.label}: the price book was not changed.#{note.present? ? " #{note}" : ''}",
      action_url: price_request.deal_id ? "/deals/#{price_request.deal_id}?tab=home_build" : nil, action_text: price_request.deal_id ? 'Open the deal' : nil
    )
  rescue StandardError => e
    Rails.logger.error("[PriceRequest] notify #{price_request.id}: #{e.class} #{e.message}")
  end

  def base_row(vp, corrected)
    v = vp.variant
    { id: vp.id, kind: 'base', model_number: v.model_number, plan: v.catalog_plan.name, series: v.catalog_plan.series,
      size: [v.width_ft, v.length_ft].all? ? "#{v.width_ft}' x #{v.length_ft}'" : nil,
      net_base_price: vp.net_base_price&.to_f, total_base_price: vp.total_base_price&.to_f, base_cost: vp.base_cost.to_f,
      adders: vp.required_adders.sum { |a| a['amount'].to_d }.to_f, corrected: corrected }
  end

  def option_row(op, corrected)
    o = op.option
    { id: op.id, kind: 'option', name: o.name, factory_code: o.factory_code, group: o.group&.name, applies_to: applies_to(op),
      dealer_cost: op.dealer_cost&.to_f, suggested_retail: op.suggested_retail&.to_f, is_standard: op.is_standard, corrected: corrected }
  end

  # Which homes a row prices: one model, a series, a size band, a width.
  def applies_to(op)
    parts = []
    parts << op.variant.model_number if op.variant
    parts << op.series if op.series.present?
    parts << "#{op.min_length_ft || '?'}-#{op.max_length_ft || '?'} ft long" if op.min_length_ft || op.max_length_ft
    parts << "#{op.width_ft} ft wide" if op.width_ft
    parts << op.section_type if op.section_type.present?
    parts << op.construction if op.construction.present?
    parts << op.building_code if op.building_code.present?
    parts.empty? ? 'Every home' : parts.join(' · ')
  end

  def target_labels(rows)
    by_type = rows.group_by(&:target_type).transform_values { |cs| cs.map(&:target_id).uniq }
    labels = {}
    CatalogVariantPrice.where(id: by_type['CatalogVariantPrice'] || []).includes(variant: :catalog_plan).each do |vp|
      labels[['CatalogVariantPrice', vp.id]] = "#{vp.variant.catalog_plan.name} #{vp.variant.model_number} base"
    end
    CatalogOptionPrice.where(id: by_type['CatalogOptionPrice'] || []).includes(:option, :variant).each do |op|
      labels[['CatalogOptionPrice', op.id]] = [op.option.name, op.variant&.model_number || op.series].compact.join(' · ')
    end
    labels
  end

  def request_json(r)
    { id: r.id, status: r.status, label: r.label, field: r.field, book_field: r.book_field,
      current_value: r.current_value&.to_f, suggested_value: r.suggested_value&.to_f, note: r.note,
      company: r.company&.name, deal_id: r.deal_id, requested_by: r.requested_by&.name,
      book: { id: r.catalog_price_book_id, name: r.price_book&.name }, target_type: r.target_type, target_id: r.target_id,
      resolution_note: r.resolution_note, resolved_at: r.resolved_at, created_at: r.created_at }
  end
end
