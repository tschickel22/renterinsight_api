# frozen_string_literal: true

# A dealer's TrueBuild pricing: their terms per manufacturer (program
# discount, freight, how new price books reach them, what buyers see), their
# markup rules, and a preview of what any model and options cost and sell for.
# The catalog itself is platform data (Api::Admin::CatalogPriceBooksController);
# everything here is this company's own layer on top of it.
#
# Their price list (backlog E85), by factory book: their own price for any
# home or option, their cost when the factory's is wrong (sent to the
# platform admin, which the dealer never needs to see), their names for
# options, their own colors and the factory colors they hide.
#
#   GET    /api/v1/truebuild_pricing/price_list?book_id=&kind=base|option|color&search=&group=&page=
#   POST   /api/v1/truebuild_pricing/price_list/remember   { kind: base|option, price_id, price?, cost?, name?, note? }
#   POST   /api/v1/truebuild_pricing/colors                { manufacturer_id, color_set, name, factory_code?, cost?, retail?, replaces_id? }
#   PATCH  /api/v1/truebuild_pricing/colors/:id            { name?, factory_code?, cost?, retail? }   their own color
#   DELETE /api/v1/truebuild_pricing/colors/:id
#   POST   /api/v1/truebuild_pricing/colors/:id/hide       a factory color
#   DELETE /api/v1/truebuild_pricing/colors/:id/hide
class Api::V1::TruebuildPricingController < ApplicationController
  include ModuleAccessRequired
  require_module! Truebuild::BuyerCatalog::MODULE
  before_action :set_company_scope
  before_action :set_rule, only: %i[update_rule destroy_rule]
  before_action :set_update, only: %i[show_update accept_update decline_update]
  # A price change re-prices the site's Design Your Home list before a buyer asks.
  after_action :warm_model_list, only: %i[update_terms create_rule update_rule destroy_rule accept_update decline_update
                                          create_addon update_addon destroy_addon remember_price]

  TERM_FIELDS = %i[price_update_policy price_display program_discount_pct margin_floor_pct round_retail_to buyer_view
                   sale_discount_pct dealer_savings_pct preferred_payment_pct factory_po_hide_prices website_designer].freeze + DealerCatalogTerm::FREIGHT
  # The buyer view's lists (BuyerView); company-wide like price_display.
  BUYER_LISTS = %i[buyer_featured_option_ids buyer_hidden_option_ids buyer_hidden_groups].freeze

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
      locations: @company.locations.order(:name).map { |l| { id: l.id, name: l.name } },
      # What the deal sheet uses for freight until the dealer sets their own.
      freight_assumptions: DealerCatalogTerm::FREIGHT_ASSUMPTIONS,
      updates: @company.dealer_price_book_adoptions.where.not(previous_book_id: nil).where.not(status: 'superseded')
                       .includes(price_book: %i[manufacturer factory]).order(created_at: :desc).limit(20)
                       .map { |a| update_json(a) }
    }
  end

  # GET /api/v1/truebuild_pricing/addons
  # The dealer's package and fee templates, and which are in TrueBuild how.
  def addons
    return unless authorize_action!('company_settings', 'read')

    chosen = @company.truebuild_addons.includes(:source).order(:position, :id).to_a
    by_source = chosen.index_by { |a| [a.source_type, a.source_id] }
    templates = @company.package_templates.active.not_homes.ordered.map { |t| template_json(t, 'PackageTemplate', t.default_price, by_source) } +
                FeeTemplate.where(company_id: @company.id).active.ordered.map { |t| template_json(t, 'FeeTemplate', t.default_amount, by_source) }
    render json: { templates: templates, addons: chosen.map { |a| addon_json(a) } }
  end

  # POST /api/v1/truebuild_pricing/addons   { source_type, source_id, mode, price_override, manufacturer_id }
  def create_addon
    return unless authorize_action!('company_settings', 'update')

    addon = @company.truebuild_addons.build(addon_params.merge(source_type: params[:source_type], source_id: params[:source_id]))
    if addon.source_type.in?(TruebuildAddon::SOURCES) && addon.save
      render json: addon_json(addon), status: :created
    else
      render json: { errors: addon.errors.full_messages.presence || ['Choose one of your packages or fees'] }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/truebuild_pricing/addons/:id   { mode, price_override, manufacturer_id, active, position }
  def update_addon
    return unless authorize_action!('company_settings', 'update')

    addon = @company.truebuild_addons.find(params[:id])
    if addon.update(addon_params)
      render json: addon_json(addon)
    else
      render json: { errors: addon.errors.full_messages }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  # DELETE /api/v1/truebuild_pricing/addons/:id
  def destroy_addon
    return unless authorize_action!('company_settings', 'update')

    @company.truebuild_addons.find(params[:id]).destroy!
    head :no_content
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  # GET /api/v1/truebuild_pricing/updates/:id
  def show_update
    return unless authorize_action!('company_settings', 'read')

    render json: update_json(@update, full: true)
  end

  # POST /api/v1/truebuild_pricing/updates/:id/accept
  # Start pricing from the new book. Also undoes a decline.
  def accept_update
    return unless authorize_action!('company_settings', 'update')
    return render json: { error: 'A newer price book replaced this one' }, status: :unprocessable_entity unless @update.price_book.published?

    @update.update!(status: 'adopted', decided_at: Time.current, decided_by: current_user)
    Truebuild::DesignRepricer.call(@company)
    render json: update_json(@update, full: true)
  end

  # POST /api/v1/truebuild_pricing/updates/:id/decline
  # Keep pricing from the previous book.
  def decline_update
    return unless authorize_action!('company_settings', 'update')
    return render json: { error: 'A newer price book replaced this one' }, status: :unprocessable_entity unless @update.price_book.published?

    @update.update!(status: 'declined', decided_at: Time.current, decided_by: current_user)
    render json: update_json(@update, full: true)
  end

  # PUT /api/v1/truebuild_pricing/terms   { manufacturer_id (blank = company default), ...fields }
  def update_terms
    return unless authorize_action!('company_settings', 'update')

    manufacturer_id = params[:manufacturer_id].presence
    if manufacturer_id && !CatalogPriceBook.published.exists?(manufacturer_id: manufacturer_id)
      return render json: { error: 'No published price book for that manufacturer' }, status: :unprocessable_entity
    end

    terms = @company.dealer_catalog_terms.find_or_initialize_by(manufacturer_id: manufacturer_id)
    attrs = params.permit(*TERM_FIELDS, **BUYER_LISTS.index_with { [] }).to_h
    attrs.slice(:buyer_featured_option_ids, :buyer_hidden_option_ids).each { |k, v| attrs[k] = Array(v).map(&:to_i).uniq.first(500) }
    attrs[:buyer_hidden_groups] = Array(attrs[:buyer_hidden_groups]).map { |g| g.to_s.strip }.reject(&:empty?).uniq.first(100) if attrs.key?(:buyer_hidden_groups)
    if terms.update(attrs)
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
    book = Truebuild::OptionSource.current_for(variant)
    return render json: { groups: [] } unless book

    offered = Truebuild::OptionSource.offered(book, variant)
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

  # GET /api/v1/truebuild_pricing/option_search?q=&manufacturer_id=
  # Options by name across a manufacturer's homes, for the buyer view's
  # popular upgrades and hidden options. One name can be several catalog
  # options (one per series or plant), so each result carries all their ids.
  def option_search
    return unless authorize_action!('company_settings', 'read')

    q = params[:q].to_s.strip
    return render json: { items: [] } if q.length < 2

    scope = CatalogOption.where(status: 'active').where.not(kind: 'color').where('catalog_options.name ILIKE ?', "%#{q}%")
    scope = scope.where(manufacturer_id: params[:manufacturer_id]) if params[:manufacturer_id].present?
    items = scope.joins(:group).limit(400).pluck('catalog_options.id', 'catalog_options.name', 'catalog_option_groups.name')
                 .group_by { |_, name, _| name.strip }
                 .map { |name, rows| { name: name, group: rows.first[2], ids: rows.map(&:first).sort } }
                 .sort_by { |i| i[:name] }.first(40)
    render json: { items: items }
  end

  # GET /api/v1/truebuild_pricing/option_names?ids[]=
  # Names for saved ids, so the settings can list what is featured or hidden.
  def option_names
    return unless authorize_action!('company_settings', 'read')

    ids = Array(params[:ids]).map(&:to_i).first(1000)
    rows = CatalogOption.where(id: ids).joins(:group).pluck('catalog_options.id', 'catalog_options.name', 'catalog_option_groups.name')
    items = rows.group_by { |_, name, _| name.strip }.map { |name, rs| { name: name, group: rs.first[2], ids: rs.map(&:first).sort } }
    render json: { items: items.sort_by { |i| i[:name] } }
  end

  # POST /api/v1/truebuild_pricing/preview   { variant_id, option_ids: [], location_id, update_id }
  # With update_id, prices from that pending update's new book, so a dealer
  # can see and adjust their prices before accepting it.
  def preview
    return unless authorize_action!('company_settings', 'read')

    variant = CatalogPlanVariant.find(params[:variant_id])
    location = params[:location_id].present? ? @company.locations.find(params[:location_id]) : nil
    book = params[:update_id].present? ? @company.dealer_price_book_adoptions.find(params[:update_id]).price_book : nil
    result = Truebuild::PricingEngine.new(company: @company, variant: variant, option_ids: Array(params[:option_ids]),
                                          location: location, book: book).call
    render json: result.to_h
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /api/v1/truebuild_pricing/price_list
  def price_list
    return unless authorize_action!('company_settings', 'read')

    book = CatalogPriceBook.published.find_by(id: params[:book_id])
    return render json: { error: 'Choose a published price book' }, status: :not_found unless book

    prices = Truebuild::DealerPrices.new(@company)
    own = Truebuild::DealerOptions.new(@company, book.manufacturer_id)
    return render json: color_list(book, own) if params[:kind] == 'color'

    page = [params[:page].to_i, 1].max
    per_page = [(params[:per_page] || 50).to_i, 200].min
    q = params[:search].present? ? "%#{ActiveRecord::Base.sanitize_sql_like(params[:search].to_s.strip)}%" : nil
    if params[:kind] == 'option'
      scope = book.option_prices.joins(option: :group).where(catalog_options: { company_id: nil }).where.not(catalog_options: { kind: 'color' })
                  .includes(:variant, option: :group)
      scope = scope.where(catalog_options: { catalog_option_group_id: params[:group] }) if params[:group].present?
      scope = scope.where('catalog_options.name ILIKE :q OR catalog_options.factory_code ILIKE :q', q: q) if q
      total = scope.count
      rows = scope.order('catalog_option_groups.position, catalog_option_groups.name, LOWER(catalog_options.name), catalog_option_prices.id')
                  .offset((page - 1) * per_page).limit(per_page).map { |op| price_list_option(op, prices, own) }
      groups = CatalogOptionGroup.where(id: book.option_prices.joins(:option).select('catalog_options.catalog_option_group_id'))
                                 .order(:position, :name).map { |g| { id: g.id, name: g.name } }
    else
      scope = book.variant_prices.joins(variant: :catalog_plan).includes(variant: :catalog_plan)
      scope = scope.where('catalog_plan_variants.model_number ILIKE :q OR catalog_plans.name ILIKE :q OR catalog_plans.series ILIKE :q', q: q) if q
      total = scope.count
      rows = scope.order('catalog_plans.series, catalog_plans.name, catalog_plan_variants.model_number')
                  .offset((page - 1) * per_page).limit(per_page).map { |vp| price_list_base(vp, prices) }
      groups = []
    end
    render json: { book: { id: book.id, name: book.name, manufacturer_id: book.manufacturer_id }, rows: rows, groups: groups,
                   meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil } }
  end

  # POST /api/v1/truebuild_pricing/price_list/remember
  def remember_price
    return unless authorize_action!('company_settings', 'update')

    row = (params[:kind] == 'option' ? CatalogOptionPrice : CatalogVariantPrice)
          .joins(:price_book).merge(CatalogPriceBook.published).find_by(id: params[:price_id])
    return render json: { error: 'Not found' }, status: :not_found unless row

    target = row.is_a?(CatalogVariantPrice) ? row.variant : row.option
    ActiveRecord::Base.transaction do
      Truebuild::DealerPrices.set_retail!(company: @company, target: target, value: params[:price]) if params.key?(:price)
      if params.key?(:cost)
        label = row.is_a?(CatalogVariantPrice) ? "#{target.catalog_plan.name} #{target.model_number} base price" : "#{target.name} (#{row.price_book.name})"
        Truebuild::DealerPrices.set!(company: @company, row: row, value: params[:cost], label: label, user: current_user, note: params[:note])
      end
      if params.key?(:name) && row.is_a?(CatalogOptionPrice)
        Truebuild::DealerOptions.rename!(company: @company, option: target, name: params[:name], user: current_user, note: params[:note])
      end
    end
    fresh = Truebuild::DealerPrices.new(@company)
    render json: row.is_a?(CatalogVariantPrice) ? price_list_base(row, fresh) : price_list_option(row, fresh, Truebuild::DealerOptions.new(@company, row.option.manufacturer_id))
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/truebuild_pricing/colors
  def create_color
    return unless authorize_action!('company_settings', 'update')

    option = Truebuild::DealerOptions.add_color!(
      company: @company, manufacturer_id: params[:manufacturer_id], color_set: params[:color_set].to_s, name: params[:name],
      factory_code: params[:factory_code], cost: params[:cost], retail: params[:retail], replaces_id: params[:replaces_id].presence,
      user: current_user, note: params[:note]
    )
    render json: { id: option.id, name: option.name }, status: :created
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # PATCH /api/v1/truebuild_pricing/colors/:id
  def update_color
    return unless authorize_action!('company_settings', 'update')

    option = @company.dealer_colors.find(params[:id])
    Truebuild::DealerOptions.update_color!(option, params.permit(:name, :factory_code, :cost, :retail).to_h)
    head :no_content
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # DELETE /api/v1/truebuild_pricing/colors/:id
  def destroy_color
    return unless authorize_action!('company_settings', 'update')

    Truebuild::DealerOptions.remove_color!(@company.dealer_colors.find(params[:id]), user: current_user)
    head :no_content
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  # POST /api/v1/truebuild_pricing/colors/:id/hide
  def hide_color
    return unless authorize_action!('company_settings', 'update')

    Truebuild::DealerOptions.hide!(company: @company, option_id: params[:id], user: current_user, note: params[:note])
    head :no_content
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # DELETE /api/v1/truebuild_pricing/colors/:id/hide
  def unhide_color
    return unless authorize_action!('company_settings', 'update')

    Truebuild::DealerOptions.unhide!(company: @company, option_id: params[:id], user: current_user)
    head :no_content
  end

  private

  STATUS_WORDS = { 'open' => 'Waiting on review', 'dealer_only' => 'Kept for you', 'applied' => 'Fixed for everyone',
                   'dismissed' => 'Turned down' }.freeze

  def price_list_base(vp, prices)
    v = vp.variant
    req = prices.request_for(vp)
    { id: vp.id, kind: 'base', variant_id: v.id, model_number: v.model_number, plan: v.catalog_plan.name, series: v.catalog_plan.series,
      size: [v.width_ft, v.length_ft].all? ? "#{v.width_ft}' x #{v.length_ft}'" : nil,
      factory_cost: vp.net_base_price&.to_f, your_cost: req&.suggested_value&.to_f, cost_status: req && STATUS_WORDS[req.status],
      your_price: prices.manual_retail(v)&.to_f }
  end

  def price_list_option(op, prices, own)
    o = op.option
    req = prices.request_for(op)
    { id: op.id, kind: 'option', option_id: o.id, name: own.name_for(o), book_name: (o.name if own.renamed?(o)),
      group: o.group&.name, factory_code: o.factory_code, applies_to: applies_to_words(op), standard: op.is_standard,
      factory_cost: op.dealer_cost&.to_f, suggested_retail: op.suggested_retail&.to_f,
      your_cost: req&.suggested_value&.to_f, cost_status: req && STATUS_WORDS[req.status], your_price: prices.manual_retail(o)&.to_f }
  end

  # Which homes a row prices.
  def applies_to_words(op)
    parts = []
    parts << op.variant.model_number if op.variant
    parts << op.series if op.series.present?
    parts << "#{op.min_length_ft || '?'}-#{op.max_length_ft || '?'} ft long" if op.min_length_ft || op.max_length_ft
    parts << "#{op.width_ft} ft wide" if op.width_ft
    parts << op.section_type if op.section_type.present?
    parts.empty? ? 'Every home' : parts.join(' · ')
  end

  # Every color set the book's factory uses: its colors (hidden or not), and
  # the dealer's own colors in it. A color the book carries once per series
  # is listed once (DealerOptions.key_for); hiding it hides every copy.
  def color_list(book, own)
    in_book = CatalogOption.where(id: book.option_prices.select(:catalog_option_id)).platform.where(kind: 'color', status: 'active')
                           .where("metadata->>'color_set' IS NOT NULL").order(:id).to_a
    sets = in_book.group_by { |o| o.metadata['color_set'] }.map do |set, options|
      colors = options.uniq { |o| Truebuild::DealerOptions.key_for(o) }.sort_by { |o| own.name_for(o).to_s.downcase }
      { set: set,
        colors: colors.map { |o| { id: o.id, name: own.name_for(o), book_name: (o.name if own.renamed?(o)), factory_code: o.factory_code,
                                   hidden: own.hidden?(o) } },
        yours: own.colors.select { |o| o.metadata.to_h['color_set'] == set }.map do |o|
          { id: o.id, name: o.name, factory_code: o.factory_code, cost: o.metadata['cost']&.to_f, retail: o.metadata['retail']&.to_f }
        end }
    end
    { book: { id: book.id, name: book.name, manufacturer_id: book.manufacturer_id }, sets: sets.sort_by { |x| x[:set].to_s } }
  end

  def warm_model_list
    TruebuildModelListWarmJob.perform_later(@company.id) if response.successful?
  end

  # Never company_id or source: an add-on is built on @company from its own templates.
  def addon_params
    permitted = params.permit(:mode, :price_override, :manufacturer_id, :active, :position)
    permitted[:price_override] = nil if permitted.key?(:price_override) && permitted[:price_override].blank?
    permitted[:manufacturer_id] = nil if permitted.key?(:manufacturer_id) && permitted[:manufacturer_id].blank?
    permitted
  end

  def template_json(template, type, price, by_source)
    chosen = by_source[[type, template.id]]
    { source_type: type, source_id: template.id, name: template.name, price: price.to_f,
      kind: type == 'FeeTemplate' ? template.fee_type : 'package', addon_id: chosen&.id }
  end

  def addon_json(a)
    { id: a.id, source_type: a.source_type, source_id: a.source_id, name: a.name, mode: a.mode,
      template_price: (a.fee? ? a.source.default_amount : a.source.default_price).to_f,
      price_override: a.price_override&.to_f, price: a.price.to_f, manufacturer_id: a.manufacturer_id,
      active: a.active, position: a.position }
  end

  def set_update
    @update = @company.dealer_price_book_adoptions.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  def update_json(a, full: false)
    book = a.price_book
    json = {
      id: a.id, status: a.status, manufacturer: book.manufacturer.name, plant: book.factory&.name,
      book_id: book.id, book_name: book.name, effective_on: book.effective_on, published_at: book.published_at,
      previous_book_name: a.previous_book&.name, decided_at: a.decided_at, decided_by: a.decided_by&.full_name,
      ready: a.notified_at.present?, headline: a.summary.present? ? Truebuild::PriceBookNotifier.headline(a.summary) : nil,
      can_decide: book.published?
    }
    json[:summary] = a.summary if full
    json
  end

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
    t.slice(:id, :manufacturer_id, *TERM_FIELDS, *BUYER_LISTS).transform_values { |v| v.is_a?(BigDecimal) ? v.to_f : v }
  end

  def rule_json(r)
    { id: r.id, scope_type: r.scope_type, manufacturer_id: r.manufacturer_id, scope_value: r.scope_value,
      scope_id: r.scope_id, scope_label: scope_label(r), applies_to: r.applies_to, markup_type: r.markup_type,
      value: r.value.to_f, location_id: r.location_id, location_name: r.location&.name, active: r.active }
  end

  def scope_label(r)
    case r.scope_type
    when 'all' then 'Every home'
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
