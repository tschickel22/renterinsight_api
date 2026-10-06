# frozen_string_literal: true

# The home on a deal and the options chosen for it (backlog E49), for staff.
# Lines carry cost: cost on a deal is visible to deal readers by design. A
# buyer never reaches this controller.
#
#   GET    /api/v1/deals/:deal_id/home_build                 build, or what it could start from
#   POST   /api/v1/deals/:deal_id/home_build                 { variant_id, vehicle_id?, design_id? }
#   PATCH  /api/v1/deals/:deal_id/home_build                 { variant_id?, construction?, notes? }
#   DELETE /api/v1/deals/:deal_id/home_build
#   GET    /api/v1/deals/:deal_id/home_build/models          priced models the dealer can build
#   GET    /api/v1/deals/:deal_id/home_build/options         the model's options by group
#   POST   /api/v1/deals/:deal_id/home_build/reprice
#   POST   /api/v1/deals/:deal_id/home_build/lines           { kind: option|addon|custom, ... }
#   PATCH  /api/v1/deals/:deal_id/home_build/lines/:id
#   DELETE /api/v1/deals/:deal_id/home_build/lines/:id
class Api::V1::DealHomeBuildsController < ApplicationController
  include ModuleAccessRequired
  require_module! Truebuild::BuyerCatalog::MODULE
  before_action :set_company_scope
  before_action :set_deal
  before_action :set_build, except: %i[show create models]

  rescue_from Truebuild::DealBuild::Locked do |e|
    render json: { error: e.message }, status: :conflict
  end

  def show
    return unless authorize_action!('deals', 'read')

    build = @deal.home_build
    render json: build ? build_json(build) : { build: nil, start_from: start_from }
  end

  def create
    return unless authorize_action!('deals', 'update')
    return render json: { error: 'This deal already has a home build' }, status: :unprocessable_entity if @deal.home_build

    variant = priced_variant(params[:variant_id]) or return
    vehicle = params[:vehicle_id].present? ? @company.vehicles.find_by(id: params[:vehicle_id]) : nil
    return render json: { error: 'Home not found' }, status: :not_found if params[:vehicle_id].present? && !vehicle

    design = params[:design_id].present? ? @company.truebuild_designs.find_by(id: params[:design_id]) : nil
    return render json: { error: 'Design not found' }, status: :not_found if params[:design_id].present? && !design

    service = Truebuild::DealBuild.start(deal: @deal, variant: design&.variant || variant, vehicle: vehicle, design: design, user: current_user)
    render json: build_json(service.build, service.warnings), status: :created
  end

  def update
    return unless authorize_action!('deals', 'update')

    service = Truebuild::DealBuild.new(@build)
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
      service.reprice!
    end
    render json: build_json(@build.reload, service.warnings)
  end

  def destroy
    return unless authorize_action!('deals', 'update')
    return render json: { error: 'This build is locked by a signed agreement' }, status: :conflict if @build.locked?

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
    groups = rows.group_by { |op| op.option.group }.sort_by { |g, _| [g&.position.to_i, g&.name.to_s] }.map do |group, ops|
      { id: group&.id, name: group&.name, selection_type: group&.selection_type, required: group&.required,
        options: most_specific(ops).map do |op|
          { id: op.catalog_option_id, name: op.option.name, kind: op.option.kind, standard: op.is_standard,
            color_set: Truebuild::DealBuild.choice_set(op.option),
            cost: op.dealer_cost&.to_f, suggested_retail: op.suggested_retail&.to_f, factory_code: op.option.factory_code,
            unit: DealHomeBuildLine.unit_for(op.option.name), chosen: chosen.include?(op.catalog_option_id),
            rules: rules.fetch(op.catalog_option_id, []).map { |_, type, target| { type: type, option_id: target } } }
        end.sort_by { |o| o[:name].to_s } }
    end
    render json: { book_id: book&.id, book_name: book&.name, groups: groups,
                   addons: @company.truebuild_addons.active.for_manufacturer(variant.manufacturer_id).order(:position, :id)
                                   .map { |a| { id: a.id, name: a.name, mode: a.mode, price: a.price.to_f, cost: a.cost.to_f } } }
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
    when 'custom'
      service.add_custom(**params.permit(:label, :unit_retail, :unit_cost, :quantity, :unit, :tax_category, :group_name).to_h.symbolize_keys)
    else
      return render json: { error: 'kind must be option, addon or custom' }, status: :unprocessable_entity
    end
    render json: build_json(@build.reload, service.warnings), status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
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

  private

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
    @build = @deal.home_build
    render json: { error: 'This deal has no home build' }, status: :not_found unless @build
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
      model: model_json(variant, Truebuild::HomeMatcher.new).merge(factory: variant.catalog_plan.factory&.name,
                                                                   series: variant.catalog_plan.series),
      vehicle: build.vehicle && { id: build.vehicle.id, stock_number: build.vehicle.stock_number,
                                  title: [build.vehicle.year, build.vehicle.make, build.vehicle.model].compact.join(' ') },
      design_id: build.truebuild_design_id,
      books: { base: build.price_book&.name, cost: build.cost_book&.name, options: build.options_book&.name },
      totals: build.totals,
      warnings: warnings || build.totals['warnings'] || [],
      lines: build.lines.map { |l| line_json(l) }
    } }
  end

  def line_json(l)
    { id: l.id, kind: l.kind, option_id: l.catalog_option_id, addon_id: l.truebuild_addon_id, group: l.group_name, label: l.label,
      factory_code: l.factory_code, quantity: l.quantity.to_f, unit: l.unit, unit_cost: l.unit_cost&.to_f, unit_retail: l.unit_retail&.to_f,
      cost: l.cost&.to_f, retail: l.retail&.to_f, standard: l.is_standard, tbd: l.tbd, no_charge: l.no_charge,
      tax_category: l.tax_category, set_retail: l.metadata['set_retail'] == true, not_offered: l.metadata['not_offered'] == true,
      rule: l.metadata['rule'], notes: l.metadata['notes'], base: l.metadata['base'] }
  end

  def model_json(v, matcher)
    # Books often leave square feet blank; the box size gives it.
    sq_ft = v.square_feet.presence || (v.width_ft.to_i * v.length_ft.to_i).nonzero?
    matcher.variant_json(v).merge(beds: v.beds, baths: v.baths&.to_f, square_feet: sq_ft, width_ft: v.width_ft,
                                  length_ft: v.length_ft, section: v.width_ft.to_i <= 18 ? 'single' : 'multi')
  end
end
