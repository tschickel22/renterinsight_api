# frozen_string_literal: true

# A dealer's TrueBuild pricing: their terms per manufacturer (program
# discount, freight, how new price books reach them, what buyers see), their
# markup rules, and a preview of what any model and options cost and sell for.
# The catalog itself is platform data (Api::Admin::CatalogPriceBooksController);
# everything here is this company's own layer on top of it.
class Api::V1::TruebuildPricingController < ApplicationController
  before_action :set_company_scope
  before_action :set_rule, only: %i[update_rule destroy_rule]

  TERM_FIELDS = %i[price_update_policy price_display program_discount_pct freight_per_mile freight_flat freight_miles
                   margin_floor_pct round_retail_to].freeze

  # GET /api/v1/truebuild_pricing
  def show
    return unless authorize_action!('company_settings', 'read')

    books = CatalogPriceBook.published.includes(:manufacturer, :factory).to_a
    manufacturers = books.group_by(&:manufacturer).map do |mfr, bs|
      terms = @company.dealer_catalog_terms.find_by(manufacturer_id: mfr.id)
      { id: mfr.id, name: mfr.name,
        plants: bs.map { |b| { book_id: b.id, book: b.name, plant: b.factory&.name, published_at: b.published_at } },
        series: CatalogPlan.where(manufacturer_id: mfr.id).distinct.order(:series).pluck(:series),
        groups: CatalogOptionGroup.where(manufacturer_id: mfr.id).order(:position, :name).map { |g| { id: g.id, name: g.name } },
        terms: terms && term_json(terms) }
    end

    render json: {
      defaults: term_json(@company.dealer_catalog_terms.find_by(manufacturer_id: nil) || @company.dealer_catalog_terms.new),
      manufacturers: manufacturers,
      rules: @company.dealer_markup_rules.order(:scope_type, :id).map { |r| rule_json(r) },
      locations: @company.locations.order(:name).map { |l| { id: l.id, name: l.name } }
    }
  end

  # PUT /api/v1/truebuild_pricing/terms   { manufacturer_id (blank = company default), ...fields }
  def update_terms
    return unless authorize_action!('company_settings', 'update')

    manufacturer_id = params[:manufacturer_id].presence
    if manufacturer_id && !CatalogPriceBook.published.exists?(manufacturer_id: manufacturer_id)
      return render json: { error: 'No published price book for that manufacturer' }, status: :unprocessable_entity
    end

    terms = @company.dealer_catalog_terms.find_or_initialize_by(manufacturer_id: manufacturer_id)
    if terms.update(params.permit(*TERM_FIELDS))
      render json: term_json(terms)
    else
      render json: { errors: terms.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/truebuild_pricing/rules
  def create_rule
    return unless authorize_action!('company_settings', 'update')

    rule = @company.dealer_markup_rules.build(rule_params)
    if rule.save
      render json: rule_json(rule), status: :created
    else
      render json: { errors: rule.errors.full_messages }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    render json: { errors: ['A rule for exactly that already exists; edit it instead'] }, status: :unprocessable_entity
  end

  # PATCH /api/v1/truebuild_pricing/rules/:id
  def update_rule
    return unless authorize_action!('company_settings', 'update')

    if @rule.update(rule_params)
      render json: rule_json(@rule)
    else
      render json: { errors: @rule.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/truebuild_pricing/rules/:id
  def destroy_rule
    return unless authorize_action!('company_settings', 'update')

    @rule.destroy!
    head :no_content
  end

  # GET /api/v1/truebuild_pricing/plans?manufacturer_id=
  def plans
    return unless authorize_action!('company_settings', 'read')

    books = CatalogPriceBook.published.where(manufacturer_id: params[:manufacturer_id]).pluck(:id)
    variants = CatalogVariantPrice.where(catalog_price_book_id: books).includes(variant: :catalog_plan).map(&:variant)
    plans = variants.group_by(&:catalog_plan).map do |plan, vs|
      { id: plan.id, name: plan.name, series: plan.series,
        variants: vs.sort_by(&:model_number).map { |v| variant_json(v) } }
    end.sort_by { |p| [p[:series].to_s, p[:name].to_s] }
    render json: { plans: plans }
  end

  # GET /api/v1/truebuild_pricing/options?variant_id=
  # Options offered on this model, by group.
  def options
    return unless authorize_action!('company_settings', 'read')

    variant = CatalogPlanVariant.find(params[:variant_id])
    book = Truebuild::BookResolver.book_for(@company, variant)
    return render json: { groups: [] } unless book

    offered = book.option_prices.includes(option: :group).select { |op| op.applies_to?(variant) }
    groups = offered.group_by { |op| op.option.group }.sort_by { |g, _| [g.position.to_i, g.name] }.map do |g, ops|
      { id: g.id, name: g.name,
        options: ops.uniq(&:catalog_option_id).map do |op|
          { id: op.option.id, name: op.option.name, kind: op.option.kind, standard: op.is_standard,
            cost: op.dealer_cost&.to_f, suggested_retail: op.suggested_retail&.to_f, for_this_model: op.catalog_plan_variant_id.present? }
        end.sort_by { |o| o[:name].to_s } }
    end
    render json: { book_id: book.id, groups: groups }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Model not found' }, status: :not_found
  end

  # POST /api/v1/truebuild_pricing/preview   { variant_id, option_ids: [], location_id }
  def preview
    return unless authorize_action!('company_settings', 'read')

    variant = CatalogPlanVariant.find(params[:variant_id])
    location = params[:location_id].present? ? @company.locations.find(params[:location_id]) : nil
    result = Truebuild::PricingEngine.new(company: @company, variant: variant, option_ids: Array(params[:option_ids]),
                                          location: location).call
    render json: result.to_h
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_rule
    @rule = @company.dealer_markup_rules.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  # Never company_id: rules are built on @company.
  def rule_params
    permitted = params.permit(:scope_type, :manufacturer_id, :scope_value, :scope_id, :applies_to, :markup_type, :value,
                              :location_id, :active)
    if permitted[:location_id].present? && !@company.locations.exists?(id: permitted[:location_id])
      permitted[:location_id] = nil
    end
    permitted
  end

  def term_json(t)
    t.slice(:id, :manufacturer_id, *TERM_FIELDS).transform_values { |v| v.is_a?(BigDecimal) ? v.to_f : v }
  end

  def rule_json(r)
    { id: r.id, scope_type: r.scope_type, manufacturer_id: r.manufacturer_id, scope_value: r.scope_value,
      scope_id: r.scope_id, scope_label: scope_label(r), applies_to: r.applies_to, markup_type: r.markup_type,
      value: r.value.to_f, location_id: r.location_id, location_name: r.location&.name, active: r.active }
  end

  def scope_label(r)
    case r.scope_type
    when 'all' then 'Everything'
    when 'manufacturer' then r.manufacturer&.name
    when 'series' then "#{r.manufacturer&.name} #{r.scope_value}"
    when 'plan' then CatalogPlan.find_by(id: r.scope_id)&.name
    when 'variant' then CatalogPlanVariant.find_by(id: r.scope_id)&.model_number
    when 'option_group' then "#{CatalogOptionGroup.find_by(id: r.scope_id)&.name} options"
    when 'option' then CatalogOption.find_by(id: r.scope_id)&.name
    end
  end

  def variant_json(v)
    { id: v.id, model_number: v.model_number, building_code: v.building_code, width_ft: v.width_ft, length_ft: v.length_ft,
      beds: v.beds, baths: v.baths&.to_f }
  end
end
