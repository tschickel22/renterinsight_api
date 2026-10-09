# frozen_string_literal: true

# The home on a deal and the options chosen for it (backlog E49), for staff.
# Lines carry cost: cost on a deal is visible to deal readers by design. A
# buyer never reaches this controller.
#
# Every call works on the LIVE version unless it passes version_id.
#
#   GET    /api/v1/deals/:deal_id/home_build                 build, or what it could start from
#   POST   /api/v1/deals/:deal_id/home_build                 { variant_id, vehicle_id?, design_id? }
#   PATCH  /api/v1/deals/:deal_id/home_build                 { label?, variant_id?, construction?, notes?, freight_miles?, discounts?,
#                                                              deal: { trade_allowance, trade_payoff, down_payment, delivery_point, delivery_state } }
#   DELETE /api/v1/deals/:deal_id/home_build
#   POST   /api/v1/deals/:deal_id/home_build/versions        { copy_from_id? | variant_id, label?, live? } a new version
#   POST   /api/v1/deals/:deal_id/home_build/make_live       { version_id } that version writes the deal
#   GET    /api/v1/deals/:deal_id/home_build/models          priced models the dealer can build
#   GET    /api/v1/deals/:deal_id/home_build/options         the model's options by group
#   POST   /api/v1/deals/:deal_id/home_build/reprice
#   POST   /api/v1/deals/:deal_id/home_build/lines           { kind: option|addon|template|custom, ... }
#   PATCH  /api/v1/deals/:deal_id/home_build/lines/:id
#   DELETE /api/v1/deals/:deal_id/home_build/lines/:id
#   POST   /api/v1/deals/:deal_id/home_build/lines/:id/report_price   { field: price|cost, suggested_value, note }
#   GET    /api/v1/deals/:deal_id/home_build/suppliers                suppliers for the factory PO, the likely one first
#   POST   /api/v1/deals/:deal_id/home_build/purchase_order           { supplier_id | supplier_name, expected_delivery_date?, notes? }
#   POST   /api/v1/deals/:deal_id/home_build/purchase_order/:po_id/refresh   rewrite a draft PO from the sheet
class Api::V1::DealHomeBuildsController < ApplicationController
  include ModuleAccessRequired
  require_module! Truebuild::BuyerCatalog::MODULE
  before_action :set_company_scope
  before_action :set_deal
  before_action :set_build, except: %i[show create models create_version]

  # What PATCH changes besides a version's name.
  EDIT_KEYS = %w[variant_id construction notes deal freight_miles discounts].freeze

  rescue_from Truebuild::DealBuild::Locked do |e|
    render json: { error: e.message }, status: :conflict
  end
  rescue_from Truebuild::FactoryOrder::Refused do |e|
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def show
    return unless authorize_action!('deals', 'read')

    build = params[:version_id].present? ? @deal.home_builds.find_by(id: params[:version_id]) : @deal.home_build
    return render json: { error: 'That version is not on this deal' }, status: :not_found if params[:version_id].present? && !build
    return render json: { build: nil, start_from: start_from } unless build

    # A Products save or an older sheet: bring the numbers up to date before showing them.
    if Truebuild::DealBuild.stale?(build)
      service = Truebuild::DealBuild.new(build).reprice!
      return render json: build_json(build.reload, service.warnings)
    end
    render json: build_json(build)
  end

  def create
    return unless authorize_action!('deals', 'update')
    return render json: { error: 'This deal already has a home build' }, status: :unprocessable_entity if @deal.home_builds.exists?

    variant = priced_variant(params[:variant_id]) or return
    vehicle = params[:vehicle_id].present? ? @company.vehicles.find_by(id: params[:vehicle_id]) : nil
    return render json: { error: 'Home not found' }, status: :not_found if params[:vehicle_id].present? && !vehicle

    design = params[:design_id].present? ? @company.truebuild_designs.find_by(id: params[:design_id]) : nil
    return render json: { error: 'Design not found' }, status: :not_found if params[:design_id].present? && !design

    service = Truebuild::DealBuild.start(deal: @deal, variant: design&.variant || variant, vehicle: vehicle, design: design, user: current_user)
    render json: build_json(service.build, service.warnings), status: :created
  end

  # A second version: a copy of one already on the deal, or a different home
  # from scratch. A draft unless live: true.
  def create_version
    return unless authorize_action!('deals', 'update')

    if params[:copy_from_id].present?
      source = @deal.home_builds.find_by(id: params[:copy_from_id])
      return render json: { error: 'That version is not on this deal' }, status: :not_found unless source

      service = Truebuild::DealBuild.new(source).copy(label: params[:label], user: current_user)
      service.make_live! if ActiveModel::Type::Boolean.new.cast(params[:live])
    else
      variant = priced_variant(params[:variant_id]) or return
      service = Truebuild::DealBuild.start(deal: @deal, variant: variant, user: current_user, label: params[:label],
                                           live: ActiveModel::Type::Boolean.new.cast(params[:live]))
    end
    render json: build_json(service.build.reload, service.warnings), status: :created
  end

  def make_live
    return unless authorize_action!('deals', 'update')

    service = Truebuild::DealBuild.new(@build).make_live!
    render json: build_json(@build.reload, service.warnings)
  end

  def update
    return unless authorize_action!('deals', 'update')

    service = Truebuild::DealBuild.new(@build)
    # A version's name is the rep's, and can change even once it is signed.
    @build.update!(label: params[:label].presence) if params.key?(:label)
    # Color sets marked "Not on this home" (Colors & finishes checklist).
    if params.key?(:color_skips)
      raise Truebuild::DealBuild::Locked, 'This build is locked by a signed agreement' if @build.locked?

      @build.update!(metadata: @build.metadata.to_h.merge('color_skips' => Array(params[:color_skips]).map(&:to_s).reject(&:blank?).uniq))
    end
    if (params.key?(:label) || params.key?(:color_skips)) && (params.keys & EDIT_KEYS).empty?
      return render json: build_json(@build.reload)
    end

    if params[:variant_id].present? && params[:variant_id].to_i != @build.catalog_plan_variant_id
      # A different home: its options are not this one's, so the build starts over.
      variant = priced_variant(params[:variant_id]) or return
      raise Truebuild::DealBuild::Locked, 'This build is locked by a signed agreement' if @build.locked?

      @build.lines.delete_all
      vehicle = @build.vehicle&.catalog_plan_variant_id == variant.id ? @build.vehicle : nil
      @build.update!(variant: variant, vehicle: vehicle, source: vehicle ? 'lot' : 'order')
      service.seed
    else
      raise Truebuild::DealBuild::Locked, 'This build is locked by a signed agreement' if @build.locked?

      @build.update!(params.permit(:construction, :notes).to_h)
      # The sale terms the sheet shows live on the deal: trade-in, down
      # payment, and where the buyer takes the home (which state taxes it).
      if params[:deal].present?
        attrs = params.require(:deal).permit(:trade_allowance, :trade_payoff, :down_payment, :additional_payment,
                                             :delivery_point, :delivery_state).to_h
        if attrs.key?('delivery_point') && !%w[deliver lot].include?(attrs['delivery_point'])
          return render json: { error: 'delivery_point must be deliver or lot' }, status: :unprocessable_entity
        end
        @deal.update!(attrs.slice(*@deal.attribute_names))
      end
      if params.key?(:freight_miles)
        service.set_freight_miles(params[:freight_miles])
      elsif params[:discounts].present?
        service.set_discounts(params.require(:discounts).permit(:savings_pct, :sale_pct, :preferred_pct, :other_amount).to_h)
      else
        service.reprice!
      end
    end
    render json: build_json(@build.reload, service.warnings)
  end

  def destroy
    return unless authorize_action!('deals', 'update')
    return render json: { error: 'This build is locked by a signed agreement' }, status: :conflict if @build.locked?
    if @build.live? && @deal.home_builds.where.not(id: @build.id).exists?
      return render json: { error: 'This is the LIVE version. Make another version live before deleting it.' }, status: :unprocessable_entity
    end

    Truebuild::DealBuild.new(@build).release_deal! if @build.live?
    @build.destroy!
    head :no_content
  end

  # Priced models by plan, from the factories a platform admin gave the
  # dealer (released for buyers or not: a rep pricing a deal needs no
  # drawings), or every priced model when none are set.
  def models
    return unless authorize_action!('deals', 'read')

    matcher = Truebuild::HomeMatcher.new
    variants = CatalogPlanVariant.where(id: matcher.variants.map(&:id)).includes(:manufacturer, catalog_plan: :factory).to_a
    given = @company.dealer_factories.pluck(:factory_id)
    variants = variants.select { |v| given.include?(v.catalog_plan&.factory_id) } if given.any?
    plans = variants.group_by(&:catalog_plan).map do |plan, vs|
      { id: plan.id, name: plan.name, series: plan.series, manufacturer: vs.first.manufacturer&.name, factory: plan.factory&.name,
        variants: vs.sort_by(&:model_number).map { |v| model_json(v, matcher) } }
    end
    render json: { plans: plans.sort_by { |p| [p[:manufacturer].to_s, p[:series].to_s, p[:name].to_s] } }
  end

  def options
    return unless authorize_action!('deals', 'read')

    variant = @build.variant
    book = Truebuild::OptionSource.current_for(variant)
    rows = Truebuild::OptionSource.offered(book, variant, construction: @build.construction).select { |op| op.option.status == 'active' }
    chosen = @build.lines.where(kind: 'option').pluck(:catalog_option_id).to_set
    ids = rows.map(&:catalog_option_id).uniq
    rules = CatalogOptionRule.approved.where(catalog_option_id: ids).pluck(:catalog_option_id, :rule_type, :target_option_id)
                             .group_by(&:first)
    # By section, not group record: a color shared by two factories sits in
    # one factory's group, and Flooring showed up twice on the other's homes.
    sections = rows.group_by { |op| op.option.group&.key || op.option.group&.name }
    groups = sections.values.map { |ops| [ops.map { |op| op.option.group }.compact.min_by(&:id), ops] }
                     .sort_by { |g, _| [g&.position.to_i, g&.name.to_s] }.map do |group, ops|
      { id: group&.id, name: group&.name, selection_type: group&.selection_type, required: group&.required,
        options: most_specific(ops).map do |op|
          { id: op.catalog_option_id, name: op.option.name, kind: op.option.kind, standard: op.is_standard,
            color_set: Truebuild::DealBuild.choice_set(op.option),
            cost: op.dealer_cost&.to_f, suggested_retail: op.suggested_retail&.to_f, factory_code: op.option.factory_code,
            includes: Array(op.option.package_items).map(&:to_s),
            unit: DealHomeBuildLine.unit_for(op.option.name), chosen: chosen.include?(op.catalog_option_id),
            rules: rules.fetch(op.catalog_option_id, []).map { |_, type, target| { type: type, option_id: target } } }
        end.sort_by { |o| o[:name].to_s } }
    end
    render json: { book_id: book&.id, book_name: book&.name, groups: groups,
                   addons: @company.truebuild_addons.active.for_manufacturer(variant.manufacturer_id).order(:position, :id)
                                   .map { |a| { id: a.id, name: a.name, mode: a.mode, price: a.price.to_f, cost: a.cost.to_f } },
                   # The same fee and package templates Products and the Deal Desk offer.
                   templates: templates_json }
  end

  def reprice
    return unless authorize_action!('deals', 'update')

    service = Truebuild::DealBuild.new(@build).reprice!
    render json: build_json(@build.reload, service.warnings)
  end

  def create_line
    return unless authorize_action!('deals', 'update')

    service = Truebuild::DealBuild.new(@build)
    case params[:kind]
    when 'option'
      return render json: { error: 'That option is not offered on this home' }, status: :unprocessable_entity unless offered_option?(params[:option_id])

      service.add_option(params[:option_id].to_i, quantity: (params[:quantity].presence || 1).to_d)
    when 'addon'
      service.add_addon(params[:addon_id])
    when 'template'
      service.add_template(params[:template_type], params[:template_id])
    when 'custom'
      service.add_custom(**params.permit(:label, :unit_retail, :unit_cost, :quantity, :unit, :tax_category, :group_name).to_h.symbolize_keys)
    else
      return render json: { error: 'kind must be option, addon, template or custom' }, status: :unprocessable_entity
    end
    render json: build_json(@build.reload, service.warnings), status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update_line
    return unless authorize_action!('deals', 'update')

    line = @build.lines.find(params[:id])
    attrs = params.permit(:quantity, :unit, :tbd, :no_charge, :tax_category, :notes, :unit_retail, :label, :group_name, :unit_cost).to_h
    attrs['unit_retail'] = nil if params.key?(:unit_retail) && params[:unit_retail].blank?
    service = Truebuild::DealBuild.new(@build)
    service.update_line(line, attrs)
    render json: build_json(@build.reload, service.warnings)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  def destroy_line
    return unless authorize_action!('deals', 'update')

    line = @build.lines.find(params[:id])
    service = Truebuild::DealBuild.new(@build)
    service.remove_line(line)
    render json: build_json(@build.reload, service.warnings)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Suppliers to send the factory PO to; the one named for the home's
  # manufacturer (and plant) first.
  def suppliers
    return unless authorize_action!('inventory', 'read')

    list = @company.suppliers.where(is_deleted: [false, nil]).order(Arel.sql('LOWER(name)')).limit(500).to_a
    mfr = @build.variant.manufacturer&.name.to_s
    plant = @build.variant.catalog_plan.factory&.name.to_s
    score = ->(s) { n = s.name.to_s.downcase; (mfr.present? && n.include?(mfr.downcase.split.first.to_s) ? 2 : 0) + (plant.present? && n.include?(plant.downcase) ? 1 : 0) }
    suggested = list.max_by(&score)
    suggested = nil if suggested && score.call(suggested).zero?
    # Manufacturers the dealer works with (Settings, Manufacturer/Warranty), the
    # home's own first: ordering from one emails its PO contact.
    home_mfr = @build.variant.manufacturer
    mfrs = Manufacturer.where(id: @company.company_manufacturers.active.select(:manufacturer_id)).or(Manufacturer.where(id: home_mfr&.id)).to_a
    cms = @company.company_manufacturers.where(manufacturer_id: mfrs.map(&:id)).index_by(&:manufacturer_id)
    manufacturers = mfrs.sort_by { |m| [m.id == home_mfr&.id ? 0 : 1, m.name.to_s.downcase] }.map do |m|
      { id: m.id, name: m.name, po_email: cms[m.id]&.effective_po_email || m.po_email.presence || m.contact_email }
    end
    render json: { suppliers: list.map { |s| { id: s.id, name: s.name } }, suggested_id: suggested&.id,
                   manufacturers: manufacturers, suggested_manufacturer_id: home_mfr&.id,
                   new_name: [mfr.presence, plant.presence].compact.join(' ') }
  end

  def create_purchase_order
    return unless authorize_action!('inventory', 'create')

    manufacturer = params[:manufacturer_id].present? ? Manufacturer.visible_to_company(@company.id).find_by(id: params[:manufacturer_id]) : nil
    return render json: { error: 'Manufacturer not found' }, status: :not_found if params[:manufacturer_id].present? && !manufacturer

    supplier = if manufacturer
                 Truebuild::FactoryOrder.supplier_for(@company, manufacturer)
               elsif params[:supplier_id].present?
                 @company.suppliers.find_by(id: params[:supplier_id])
               elsif params[:supplier_name].present?
                 @company.suppliers.create!(name: params[:supplier_name].to_s.strip)
               end
    return render json: { error: 'Choose the factory to send it to' }, status: :unprocessable_entity unless supplier

    po = Truebuild::FactoryOrder.new(@build).create!(supplier: supplier, user: current_user, manufacturer: manufacturer,
                                                     expected_delivery_date: params[:expected_delivery_date], notes: params[:notes])
    render json: { purchase_order: purchase_order_json(po), build: build_json(@build.reload)[:build] }, status: :created
  end

  def refresh_purchase_order
    return unless authorize_action!('inventory', 'update')

    po = @deal.purchase_orders.find_by(id: params[:po_id])
    return render json: { error: 'Purchase order not found' }, status: :not_found unless po

    Truebuild::FactoryOrder.new(@build).refresh!(po)
    render json: { purchase_order: purchase_order_json(po.reload), build: build_json(@build.reload)[:build] }
  end

  # The price book has this line wrong: the rep sets the right figure on the
  # deal and tells the platform team, who correct the book for every dealer.
  def report_price
    return unless authorize_action!('deals', 'update')

    line = @build.lines.find(params[:id])
    field = params[:field].to_s
    return render json: { error: 'field must be price or cost' }, status: :unprocessable_entity unless CatalogPriceRequest::FIELDS.include?(field)

    target = book_row_for(line)
    unless target
      return render json: { error: 'This line is not from a price book, so there is nothing to correct there' }, status: :unprocessable_entity
    end
    if target.is_a?(CatalogVariantPrice) && field == 'price'
      return render json: { error: "A home's retail comes from your markup; report its base price (cost) instead" }, status: :unprocessable_entity
    end

    current = target.is_a?(CatalogVariantPrice) ? target.net_base_price : (field == 'price' ? target.suggested_retail : target.dealer_cost)
    req = @company.catalog_price_requests.create!(
      price_book: target.price_book, target_type: target.class.name, target_id: target.id, field: field,
      current_value: current, suggested_value: params[:suggested_value].presence, note: params[:note].presence,
      label: line.kind == 'base' ? "#{@build.variant.catalog_plan.name} #{@build.variant.model_number} base price" :
                                   "#{line.label} on #{@build.variant.model_number}",
      deal: @deal, requested_by: current_user
    )
    render json: { request: { id: req.id, status: req.status, label: req.label } }, status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  private

  # The price book row that priced a line: the home's base, or the option's
  # most specific row in the book its options come from.
  def book_row_for(line)
    variant = @build.variant
    case line.kind
    when 'base'
      book = @build.cost_book || @build.price_book
      book&.variant_prices&.find_by(catalog_plan_variant_id: variant.id)
    when 'option'
      book = @build.options_book || Truebuild::OptionSource.current_for(variant)
      return nil unless book && line.catalog_option_id

      rows = Truebuild::OptionSource.offered(book, variant, construction: @build.construction, option_ids: [line.catalog_option_id])
      most_specific(rows.to_a).first
    end
  end

  def set_deal
    deals = @company.deals
    if current_user.uses_rbac? && !current_user.effective_admin?
      ids = permission_service.accessible_location_ids
      deals = deals.where(location_id: ids) if ids.any?
    end
    @deal = deals.find(params[:deal_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Deal not found or access denied' }, status: :not_found
  end

  def set_build
    if params[:version_id].present?
      @build = @deal.home_builds.find_by(id: params[:version_id])
      render json: { error: 'That version is not on this deal' }, status: :not_found unless @build
    else
      @build = @deal.home_build
      render json: { error: 'This deal has no home build' }, status: :not_found unless @build
    end
  end

  def priced_variant(id)
    variant = CatalogPlanVariant.find_by(id: id)
    return variant if variant && Truebuild::HomeMatcher.new.priced?(variant.id)

    render json: { error: 'That model is not in a published price book' }, status: :unprocessable_entity
    nil
  end

  def offered_option?(option_id)
    book = Truebuild::OptionSource.current_for(@build.variant)
    Truebuild::OptionSource.offered(book, @build.variant, construction: @build.construction, option_ids: [option_id.to_i]).any?
  end

  # One row per option: the row for this model beats a size band beats a general row.
  def most_specific(rows)
    rows.group_by(&:catalog_option_id).values.map do |cands|
      cands.max_by { |op| [op.catalog_plan_variant_id ? 1 : 0, [op.min_length_ft, op.max_length_ft, op.width_ft, op.section_type].compact.size] }
    end
  end

  # What a new build can start from: the deal's home when it is linked to a
  # model, and designs the buyer saved for this deal.
  def start_from
    vehicle = @deal.vehicle if @deal.respond_to?(:vehicle)
    matcher = Truebuild::HomeMatcher.new
    designs = @company.truebuild_designs.where(deal_id: @deal.id).includes(variant: :catalog_plan).order(created_at: :desc).limit(10)
    {
      home: vehicle && { vehicle_id: vehicle.id, title: [vehicle.year, vehicle.make, vehicle.model].compact.join(' '),
                         stock_number: vehicle.stock_number,
                         model: vehicle.catalog_plan_variant && matcher.variant_json(vehicle.catalog_plan_variant),
                         suggestions: vehicle.catalog_plan_variant_id ? [] : matcher.suggest(vehicle) },
      designs: designs.map { |d| { design_id: d.id, name: d.name, buyer_name: d.buyer_name, model: matcher.variant_json(d.variant), saved_at: d.created_at } }
    }
  end

  def build_json(build, warnings = nil)
    variant = build.variant
    { build: {
      id: build.id, deal_id: build.deal_id, status: build.status, source: build.source, construction: build.construction,
      notes: build.notes, priced_at: build.priced_at,
      version_number: build.version_number, label: build.label, live: build.live, version_name: build.version_name,
      versions: versions_json(build.deal),
      model: model_json(variant, Truebuild::HomeMatcher.new).merge(factory: variant.catalog_plan.factory&.name,
                                                                   series: variant.catalog_plan.series),
      vehicle: build.vehicle && { id: build.vehicle.id, stock_number: build.vehicle.stock_number,
                                  title: [build.vehicle.year, build.vehicle.make, build.vehicle.model].compact.join(' ') },
      design_id: build.truebuild_design_id,
      deal_terms: { delivery_point: @deal.try(:delivery_point), delivery_state: @deal.delivery_state,
                    location_state: @deal.location&.state },
      books: { base: build.price_book&.name, cost: build.cost_book&.name, options: build.options_book&.name },
      totals: build.totals,
      discounts: build.discounts,
      freight_miles_set: build.freight_miles_set,
      color_skips: build.color_skips,
      # Lines on the deal the sheet did not write (a warranty added in Products).
      other_deal_lines: other_deal_lines(build),
      warnings: warnings || build.totals['warnings'] || [],
      purchase_orders: build.deal.purchase_orders.where(kind: 'factory_home', is_deleted: [false, nil]).order(:created_at)
                            .map { |po| purchase_order_json(po) },
      lines: build.lines.includes(:option).map { |l| line_json(l) }
    } }
  end

  def line_json(l)
    { id: l.id, kind: l.kind, option_id: l.catalog_option_id, addon_id: l.truebuild_addon_id, group: l.group_name, label: l.label,
      factory_code: l.factory_code, quantity: l.quantity.to_f, unit: l.unit, unit_cost: l.unit_cost&.to_f, unit_retail: l.unit_retail&.to_f,
      cost: l.cost&.to_f, retail: l.retail&.to_f, standard: l.is_standard, tbd: l.tbd, no_charge: l.no_charge,
      tax_category: l.tax_category, set_retail: l.metadata['set_retail'] == true, set_cost: l.metadata['set_cost'] == true, not_offered: l.metadata['not_offered'] == true,
      from_products: l.metadata['from_products'] == true,
      rule: l.metadata['rule'], notes: l.metadata['notes'], base: l.metadata['base'], freight: l.metadata['freight'],
      template_type: l.source_template_type, template_id: l.source_template_id,
      # What a package holds ("PACKAGE 2" alone says nothing to a buyer).
      includes: l.kind == 'option' ? Array(l.option&.package_items).map(&:to_s) : [] }
  end

  def purchase_order_json(po)
    { id: po.id, po_number: po.po_number, status: po.status, total: po.total_amount.to_f, supplier: po.supplier&.name,
      version_number: po.sheet_snapshot.to_h['version'], changed_since: Truebuild::FactoryOrder.changed?(po),
      received_vehicle_id: po.received_vehicle_id,
      # A change order still with the factory (backlog E52).
      open_change_order: po.change_orders.open.first&.then { |co| { id: co.id, label: co.label, status: co.status } } }
  end

  # The dropdown: every version with the figures a rep compares them by.
  def versions_json(deal)
    deal.home_builds.includes(variant: :catalog_plan).map do |v|
      t = v.totals.to_h
      { id: v.id, version_number: v.version_number, label: v.label, name: v.version_name, live: v.live, status: v.status,
        model: "#{v.variant.catalog_plan.name} (#{v.variant.model_number})",
        selling_price: t['retail'], contract_total: t['contract_total'], margin_pct: t['margin_pct'], updated_at: v.updated_at }
    end
  end

  def other_deal_lines(build)
    build.deal.deal_products.reject { |dp| dp.notes.to_s.match?(Truebuild::DealBuild::TAG) || dp.home_line_item? }
         .map { |dp| { id: dp.id, name: dp.product_name, total: (dp.total.to_d - dp.tax.to_d).to_f, tax: dp.tax.to_f, cost: dp.line_cost_total } }
  end

  def templates_json
    fees = @company.fee_templates.where(active: true).ordered
                   .map { |t| { type: 'FeeTemplate', id: t.id, name: t.name, price: t.default_amount.to_f, cost: 0.0, kind: t.fee_type } }
    packages = @company.package_templates.where(is_active: true).not_homes.ordered
                       .map { |t| { type: 'PackageTemplate', id: t.id, name: t.name, price: t.default_price.to_f, cost: t.cost.to_f, kind: 'package' } }
    fees + packages
  end

  def model_json(v, matcher)
    # Books often leave square feet blank; the box size gives it.
    sq_ft = v.square_feet.presence || (v.width_ft.to_i * v.length_ft.to_i).nonzero?
    matcher.variant_json(v).merge(beds: v.beds, baths: v.baths&.to_f, square_feet: sq_ft, width_ft: v.width_ft,
                                  length_ft: v.length_ft, section: v.width_ft.to_i <= 18 ? 'single' : 'multi')
  end
end
