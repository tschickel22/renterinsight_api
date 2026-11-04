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
#                                                              deal: { trade_allowance, trade_payoff, down_payment, delivery_point, delivery_street, delivery_city, delivery_state, delivery_zip } }
#   DELETE /api/v1/deals/:deal_id/home_build
#   POST   /api/v1/deals/:deal_id/home_build/versions        { copy_from_id? | variant_id, label?, live? } a new version
#   POST   /api/v1/deals/:deal_id/home_build/make_live       { version_id } that version writes the deal
#   GET    /api/v1/deals/:deal_id/home_build/models          priced models the dealer can build
#   GET    /api/v1/deals/:deal_id/home_build/options         the model's options by group
#   POST   /api/v1/deals/:deal_id/home_build/reprice
#   POST   /api/v1/deals/:deal_id/home_build/lines           { kind: option|addon|template|freight|custom, ... }
#                                                             custom: on_addendum? (also keeps it on the dealer's list), factory_order?
#   PATCH  /api/v1/deals/:deal_id/home_build/lines/:id       { on_addendum } or the line's own fields
#   DELETE /api/v1/deals/:deal_id/home_build/lines/:id
#   POST   /api/v1/deals/:deal_id/home_build/lines/:id/report_price   { field: price|cost, suggested_value, note }
#   POST   /api/v1/deals/:deal_id/home_build/remember         { line_id | option_id, price?, cost?, surcharge? (home), name?, note? }
#                                                             the dealer's own price, cost or name on every deal (E85)
#   POST   /api/v1/deals/:deal_id/home_build/colors           { color_set, name, factory_code?, cost?, retail?, replaces_id?, note? }
#                                                             a color of the dealer's own, picked on this sheet
#   POST   /api/v1/deals/:deal_id/home_build/colors/hide      { option_id } drop a factory color from the dealer's lists
#   POST   /api/v1/deals/:deal_id/home_build/upgrades/remove  { option_id } take the dealer's own upgrade off their list
#   POST   /api/v1/deals/:deal_id/home_build/doc_fee/use      bring this sheet up to the dealer's current document fee
#   GET    /api/v1/deals/:deal_id/home_build/suppliers                suppliers for the factory PO, the likely one first
#   POST   /api/v1/deals/:deal_id/home_build/purchase_order           { supplier_id | supplier_name, expected_delivery_date?, notes? }
#   POST   /api/v1/deals/:deal_id/home_build/purchase_order/:po_id/refresh   rewrite a draft PO from the sheet
#   GET    /api/v1/deals/:deal_id/home_build/sheets?sheet=schedule_a|colors     the agreement's standard sheets (PDF; both when no sheet)
#   GET    /api/v1/deals/:deal_id/home_build/agreement        what Create agreement needs: packages, managers, the ready check
#   POST   /api/v1/deals/:deal_id/home_build/agreement        { template_id, manager_id } a draft agreement from the LIVE sheet
#   POST   /api/v1/deals/:deal_id/home_build/unlock            { reason } reopen the signed LIVE version (agreements delete permission)
#   GET    /api/v1/deals/:deal_id/home_build/buyer_change_order?version_id=   what a change order from that draft would say
#   POST   /api/v1/deals/:deal_id/home_build/buyer_change_order?version_id=   a draft change order for the buyers to sign
class Api::V1::DealHomeBuildsController < ApplicationController
  include ModuleAccessRequired
  require_module! Truebuild::BuyerCatalog::MODULE
  before_action :set_company_scope
  before_action :set_deal
  before_action :set_build, except: %i[show create models create_version]

  # What PATCH changes besides a version's name.
  EDIT_KEYS = %w[variant_id manual_home construction notes deal freight_miles discounts].freeze
  # What changes a sheet. On a won deal, it also corrects the deal.
  SHEET_EDITS = %i[make_live update reprice create_line update_line destroy_line remember create_color use_doc_fee home_status].freeze

  around_action :correction_in_one_piece, only: SHEET_EDITS

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

    # A deal with no delivery address takes the billing one, while the sheet
    # can still change (freight and tax follow it).
    filled = build.live? && Agreements::DealSheetLock.edit_problem(build).nil? && @deal.fill_delivery_address_from_billing!
    # A Products save or an older sheet: bring the numbers up to date before showing them.
    if filled || Truebuild::DealBuild.stale?(build)
      service = Truebuild::DealBuild.new(build).reprice!
      return render json: build_json(build.reload, service.warnings)
    end
    render json: build_json(build)
  end

  def create
    return unless authorize_action!('deals', 'update')
    return render json: { error: 'This deal already has a home build' }, status: :unprocessable_entity if @deal.home_builds.exists?

    variant = home_from_params or return
    vehicle = params[:vehicle_id].present? ? @company.vehicles.find_by(id: params[:vehicle_id]) : nil
    return render json: { error: 'Home not found' }, status: :not_found if params[:vehicle_id].present? && !vehicle

    design = params[:design_id].present? ? @company.truebuild_designs.find_by(id: params[:design_id]) : nil
    return render json: { error: 'Design not found' }, status: :not_found if params[:design_id].present? && !design

    @deal.fill_delivery_address_from_billing!
    service = Truebuild::DealBuild.start(deal: @deal, variant: design&.variant || variant, vehicle: vehicle, design: design, user: current_user)
    type_manual_prices(service)
    render json: build_json(service.build, service.warnings), status: :created
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # A second version: a copy of one already on the deal, or a different home
  # from scratch. A draft unless live: true.
  def create_version
    return unless authorize_action!('deals', 'update')

    # A new LIVE version replaces the current one: check that first, so a
    # refusal leaves no orphan draft behind.
    live = ActiveModel::Type::Boolean.new.cast(params[:live])
    Truebuild::DealBuild.assert_editable!(@deal.home_build) if live && @deal.home_build

    if params[:copy_from_id].present?
      source = @deal.home_builds.find_by(id: params[:copy_from_id])
      return render json: { error: 'That version is not on this deal' }, status: :not_found unless source

      service = Truebuild::DealBuild.new(source).copy(label: params[:label], user: current_user)
      service.make_live! if ActiveModel::Type::Boolean.new.cast(params[:live])
    else
      variant = home_from_params or return
      service = Truebuild::DealBuild.start(deal: @deal, variant: variant, user: current_user, label: params[:label],
                                           live: ActiveModel::Type::Boolean.new.cast(params[:live]))
      type_manual_prices(service)
    end
    render json: build_json(service.build.reload, service.warnings), status: :created
  end

  def make_live
    return unless authorize_action!('deals', 'update')

    service = sheet.make_live!
    render json: build_json(@build.reload, service.warnings)
  end

  def update
    return unless authorize_action!('deals', 'update')

    service = sheet
    # A version's name is the rep's, and can change even once it is signed.
    @build.update!(label: params[:label].presence) if params.key?(:label)
    # Color sets marked "Not on this home" (Colors & finishes checklist).
    if params.key?(:color_skips)
      Truebuild::DealBuild.assert_editable!(@build)

      @build.update!(metadata: @build.metadata.to_h.merge('color_skips' => Array(params[:color_skips]).map(&:to_s).reject(&:blank?).uniq))
    end
    # Beds, baths and size as this home really is, for this deal's paperwork.
    if params[:home_specs].present?
      Truebuild::DealBuild.assert_editable!(@build)

      specs = params.require(:home_specs).permit(*DealHomeBuild::SPEC_KEYS).to_h.transform_values(&:presence).compact
      @build.update!(metadata: @build.metadata.to_h.merge('home_specs' => specs))
      return render json: build_json(@build.reload) if (params.keys & EDIT_KEYS).empty?
    end
    if (params.key?(:label) || params.key?(:color_skips)) && (params.keys & EDIT_KEYS).empty?
      return render json: build_json(@build.reload)
    end

    if params[:manual_home].present? || (params[:variant_id].present? && params[:variant_id].to_i != @build.catalog_plan_variant_id)
      # A different home: its options are not this one's. What the rep added stays.
      Truebuild::DealBuild.assert_editable!(@build)
      variant = home_from_params or return

      vehicle = @build.vehicle&.catalog_plan_variant_id == variant.id ? @build.vehicle : nil
      service.change_home!(variant, vehicle: vehicle)
      type_manual_prices(service)
    else
      Truebuild::DealBuild.assert_editable!(@build)

      @build.update!(params.permit(:construction, :notes).to_h)
      # The sale terms the sheet shows live on the deal: trade-in, down
      # payment, and where the buyer takes the home (which state taxes it).
      if params[:deal].present?
        attrs = params.require(:deal).permit(:trade_allowance, :trade_payoff, :down_payment, :additional_payment,
                                             :delivery_point, :delivery_street, :delivery_city, :delivery_state,
                                             :delivery_zip).to_h
        if attrs.key?('delivery_point') && !%w[deliver lot].include?(attrs['delivery_point'])
          return render json: { error: 'delivery_point must be deliver or lot' }, status: :unprocessable_entity
        end
        # These live on the deal, not the version: a draft can't change them under a signed LIVE sheet.
        live = @deal.home_build
        if !@build.live? && (problem = live && Agreements::DealSheetLock.edit_problem(live))
          return render json: { error: "#{problem} Trade, payments and delivery are on the contract: unlock the sheet to change them." }, status: :conflict
        end

        moved = attrs.key?('delivery_point') && attrs['delivery_point'] != @deal.try(:delivery_point)
        @deal.update!(attrs.slice(*@deal.attribute_names))
        service.follow_delivery_point(attrs['delivery_point']) if moved
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
    problem = Agreements::DealSheetLock.edit_problem(@build)
    return render json: { error: problem }, status: :conflict if problem
    if @build.live? && @deal.cost_snapshotted?
      return render json: { error: 'This deal is won, so its sheet cannot be cleared. Correct its lines, or move the deal back to an open stage first.' }, status: :unprocessable_entity
    end
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
    return render json: manual_home_options if variant.manual_home?

    book = Truebuild::OptionSource.current_for(variant)
    chosen = @build.lines.where(kind: 'option').pluck(:catalog_option_id).to_set
    rows = Truebuild::OptionSource.for_dealer(@company, book, variant, construction: @build.construction, keep_ids: chosen.to_a)
    own = Truebuild::DealerOptions.new(@company, variant.manufacturer_id)
    prices = Truebuild::DealerPrices.new(@company)
    engine = Truebuild::PricingEngine.new(company: @company, variant: variant, location: @build.location, construction: @build.construction)
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
          dealer_cost = op.persisted? ? prices.cost_for(op) : nil
          { id: op.catalog_option_id, name: own.name_for(op.option), kind: op.option.kind, standard: op.is_standard && dealer_cost.nil?,
            color_set: Truebuild::DealBuild.choice_set(op.option),
            # The dealer's own changes (E85): their color, their name (the book's kept), their cost and price.
            dealer_color: op.option.dealer_color? && !op.option.dealer_upgrade?, dealer_upgrade: op.option.dealer_upgrade?,
            book_name: (op.option.name if own.renamed?(op.option)),
            hidden: own.hidden?(op.option),
            factory_cost: op.dealer_cost&.to_f, dealer_cost_set: dealer_cost.present?,
            your_price: prices.manual_retail(op.option)&.to_f,
            # What the dealer charges for it now, so an editor starts from the real figure.
            price: engine.retail_for(op),
            cost: (dealer_cost || op.dealer_cost)&.to_f, suggested_retail: op.suggested_retail&.to_f, factory_code: op.option.factory_code,
            includes: Array(op.option.package_items).map(&:to_s),
            unit: DealHomeBuildLine.unit_for(op.option.name), chosen: chosen.include?(op.catalog_option_id),
            rules: rules.fetch(op.catalog_option_id, []).map { |_, type, target| { type: type, option_id: target } } }
        end.sort_by { |o| o[:name].to_s } }
    end
    addons, templates = addon_lists(variant)
    render json: { book_id: book&.id, book_name: book&.name, groups: groups,
                   addons: addons.map { |a| { id: a.id, name: a.name, mode: a.mode, price: a.price.to_f, cost: a.cost.to_f } },
                   # The same fee and package templates Products and the Deal Desk offer.
                   templates: templates }
  end

  def reprice
    return unless authorize_action!('deals', 'update')

    service = sheet.reprice!
    render json: build_json(@build.reload, service.warnings)
  end

  def create_line
    return unless authorize_action!('deals', 'update')

    service = sheet
    case params[:kind]
    when 'option'
      return render json: { error: 'That option is not offered on this home' }, status: :unprocessable_entity unless offered_option?(params[:option_id])

      service.add_option(params[:option_id].to_i, quantity: (params[:quantity].presence || 1).to_d)
    when 'addon'
      service.add_addon(params[:addon_id])
    when 'template'
      service.add_template(params[:template_type], params[:template_id])
    when 'freight'
      service.add_freight
    when 'custom'
      service.add_custom(**params.permit(:label, :unit_retail, :unit_cost, :quantity, :unit, :tax_category, :group_name).to_h.symbolize_keys,
                         on_addendum: truthy?(params[:on_addendum]), factory_order: params.key?(:factory_order) ? truthy?(params[:factory_order]) : nil,
                         factory_code: params[:factory_code], user: current_user)
    else
      return render json: { error: 'kind must be option, addon, template, freight or custom' }, status: :unprocessable_entity
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
    service = sheet
    if params.key?(:on_addendum)
      service.set_addendum(line, truthy?(params[:on_addendum]), user: current_user,
                                                                 factory_order: params.key?(:factory_order) ? truthy?(params[:factory_order]) : nil)
      return render json: build_json(@build.reload, service.warnings)
    end

    if params.key?(:factory_order)
      service.set_factory_order(line, truthy?(params[:factory_order]))
      return render json: build_json(@build.reload, service.warnings)
    end

    attrs = params.permit(:quantity, :unit, :tbd, :no_charge, :tax_category, :notes, :unit_retail, :label, :group_name, :unit_cost, :surcharge).to_h
    attrs['unit_retail'] = nil if params.key?(:unit_retail) && params[:unit_retail].blank?
    attrs['surcharge'] = nil if params.key?(:surcharge) && params[:surcharge].blank?
    service.update_line(line, attrs, user: current_user)
    render json: build_json(@build.reload, service.warnings)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy_line
    return unless authorize_action!('deals', 'update')

    line = @build.lines.find(params[:id])
    service = sheet
    service.remove_line(line, user: current_user)
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

  # What the factory order would say, with nothing created.
  def preview_purchase_order
    return unless authorize_action!('deals', 'read')

    lines = Truebuild::FactoryOrder.lines(@build)
    render json: { home: Truebuild::FactoryOrder.home_name(@build), lines: lines, colors: Truebuild::FactoryOrder.colors(@build),
                   total: lines.sum { |l| l['quantity'].to_d * l['unit_cost'].to_d }.round(2).to_f,
                   tbd: @build.lines.select(&:tbd).map(&:label), left_off: @build.lines.select { |l| l.kind == 'option' && l.option&.dealer_upgrade? && l.option.metadata.to_h['factory_order'] == false }.map(&:label),
                   needs_override: @build.source == 'lot' || @build.variant.manual_home? }
  end

  # The agreement as it would print today, with nothing created.
  def preview_agreement
    return unless authorize_action!('deals', 'read')

    maker = Agreements::FromDealSheet.new(@deal, user: current_user)
    template = params[:template_id].present? ? maker.templates.find { |t| t.id == params[:template_id].to_i } : maker.templates.first
    return render json: { error: maker.package_missing }, status: :unprocessable_entity unless template

    Truebuild::DealBuild.new(@build).reprice! if Truebuild::DealBuild.stale?(@build)
    pdf = Agreements::PacketRenderer.new(@deal.reload, template, agreement_number: 'PREVIEW').call.pdf
    send_data pdf, type: 'application/pdf', disposition: 'inline', filename: 'agreement-preview.pdf'
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

    po = Truebuild::FactoryOrder.new(@build).create!(supplier: supplier, user: current_user, manufacturer: manufacturer, override: truthy?(params[:override]),
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
  # Schedule A and the Color and Finish Selections as the buyer will sign
  # them (AgreementSheetsPdfGenerator). Retail only.
  def sheets
    return unless authorize_action!('deals', 'read')

    sheets = params[:sheet].present? ? [params[:sheet].to_s] : AgreementSheetsPdfGenerator::SHEETS.keys
    unless (sheets - AgreementSheetsPdfGenerator::SHEETS.keys).empty?
      return render json: { error: 'Unknown sheet' }, status: :bad_request
    end

    pdf = AgreementSheetsPdfGenerator.new(@build, sheets: sheets).generate
    name = sheets.one? ? sheets.first.tr('_', '-') : 'agreement-sheets'
    send_data pdf, filename: "#{@deal.deal_number}-#{name}.pdf", type: 'application/pdf', disposition: 'inline'
  end

  def agreement_check
    return unless authorize_action!('agreements', 'read')

    maker = Agreements::FromDealSheet.new(@deal, user: current_user)
    # No manager is chosen yet, so the check says one is needed; the dialog
    # drops that line once the rep picks one. Assuming the viewer told a
    # platform admin (not in the list) nothing, then Create failed.
    render json: { templates: maker.templates.map { |t| { id: t.id, name: t.name } }, managers: maker.managers,
                   check: maker.check(manager: nil), live: @build.live,
                   agreements: @company.agreements.where(deal_id: @deal.id).where.not(status: 'voided').order(created_at: :desc).limit(5)
                                    .map { |a| { id: a.id, number: a.agreement_number, status: a.status, deal_sheet: a.deal_sheet_status } } }
  end

  def create_agreement
    return unless authorize_action!('agreements', 'create')
    return render json: { error: 'Make this version LIVE first: the agreement is made from the LIVE Deal Sheet' }, status: :unprocessable_entity unless @build.live

    # The trade or the homesite may have changed on the deal since this was priced.
    Truebuild::DealBuild.new(@build).reprice! if Truebuild::DealBuild.stale?(@build)
    maker = Agreements::FromDealSheet.new(@deal, user: current_user)
    template = params[:template_id].present? ? maker.templates.find { |t| t.id == params[:template_id].to_i } : maker.templates.first
    return render json: { error: 'That agreement package is not one of yours, or is not active' }, status: :unprocessable_entity if params[:template_id].present? && !template

    manager = nil
    if params[:manager_id].present?
      # Only someone the dialog offers: this company's people, still active.
      return render json: { error: 'Choose the manager from the list' }, status: :unprocessable_entity unless maker.managers.any? { |m| m[:id] == params[:manager_id].to_i }

      manager = @company.users.find(params[:manager_id])
    end
    agreement = maker.create!(template: template, manager: manager)
    render json: { agreement: { id: agreement.id, number: agreement.agreement_number }, check: maker.check(manager: manager) }, status: :created
  rescue Agreements::FromDealSheet::NotReady => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # When a signed deal has to be redone rather than changed by a change
  # order: the LIVE version opens again, with the reason recorded. The
  # agreements delete permission, as the strongest agreement action.
  def unlock
    return unless authorize_action!('agreements', 'delete')

    entry = Agreements::DealSheetLock.unlock!(@build, user: current_user, reason: params[:reason])
    render json: build_json(@build.reload).merge(unlocked: entry)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # A signed deal changes by a change order the buyers sign: the draft
  # version on screen against the signed LIVE one (Agreements::BuyerChangeOrder).
  def buyer_change_order
    return unless authorize_action!('agreements', 'read')

    co = Agreements::BuyerChangeOrder.new(@deal, @build, user: current_user)
    blocking = co.check
    render json: { blocking: blocking, number: co.number, changes: (co.changes if @deal.home_build&.locked? && !@build.live?),
                   signed: co.signed && { id: co.signed.id, number: co.signed.agreement_number } }
  end

  def create_buyer_change_order
    return unless authorize_action!('agreements', 'create')

    agreement = Agreements::BuyerChangeOrder.new(@deal, @build, user: current_user).create!
    render json: { agreement: { id: agreement.id, number: agreement.agreement_number } }, status: :created
  rescue Agreements::BuyerChangeOrder::NotReady => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def report_price
    return unless authorize_action!('deals', 'update')

    line = @build.lines.find(params[:id])
    field = params[:field].to_s
    return render json: { error: 'field must be price or cost' }, status: :unprocessable_entity unless %w[price cost].include?(field)

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

  # Saves the dealer's own price, cost or name for a sheet line or an order
  # form option, for every deal from now on, then reprices this sheet. A cost
  # also goes to the platform admin to correct the book for every dealer; a
  # name for a factory option goes to them too. Blank goes back to the book.
  def remember
    return unless authorize_action!('deals', 'update')

    line = params[:line_id].present? ? @build.lines.find(params[:line_id]) : nil
    return remember_list_item(line) if line && %w[addon template].include?(line.kind)

    option = line ? line.option : CatalogOption.find_by(id: params[:option_id])
    home = line&.kind == 'base'
    return render json: { error: 'Choose a home or factory option' }, status: :unprocessable_entity unless home || option
    if option && !home && !offered_option?(option.id) && !line
      return render json: { error: 'That option is not offered on this home' }, status: :unprocessable_entity
    end
    if option&.dealer_color? && option.company_id != @company.id
      return render json: { error: 'Not found' }, status: :not_found
    end

    Truebuild::DealBuild.assert_editable!(@build)
    variant = @build.variant
    ActiveRecord::Base.transaction do
      if params.key?(:price)
        # The dealer's own upgrade keeps its price on itself, the one Settings shows and edits.
        if !home && option&.dealer_upgrade?
          Truebuild::DealerOptions.update_color!(option, retail: params[:price])
        else
          Truebuild::DealerPrices.set_retail!(company: @company, target: home ? variant : option, value: params[:price])
        end
      end
      if params.key?(:cost)
        if option&.dealer_color?
          Truebuild::DealerOptions.update_color!(option, cost: params[:cost])
        else
          row = home ? book_row_for(line) : book_row_for_option(option.id)
          raise ArgumentError, 'This is not from a price book, so it has no factory cost' unless row

          Truebuild::DealerPrices.set!(company: @company, row: row, value: params[:cost], user: current_user, deal: @deal, note: params[:note],
                                       label: home ? "#{variant.catalog_plan.name} #{variant.model_number} base price" : "#{option.name} on #{variant.model_number}")
        end
      end
      if params.key?(:surcharge) && home
        row = book_row_for(line)
        raise ArgumentError, 'This home is not from a price book, so it has no surcharge' unless row

        Truebuild::DealerPrices.set_surcharge!(company: @company, row: row, value: params[:surcharge], user: current_user, deal: @deal,
                                               note: params[:note], label: "#{variant.catalog_plan.name} #{variant.model_number} surcharge")
      end
      if params.key?(:name) && option && !home
        Truebuild::DealerOptions.rename!(company: @company, option: option, name: params[:name], user: current_user, deal: @deal, note: params[:note])
      end
    end
    # The line's one-deal figures give way to the dealer's saved ones.
    cleared = [('set_retail' if params.key?(:price)), ('set_cost' if params.key?(:cost)), ('set_surcharge' if params.key?(:surcharge))].compact
    line.update!(metadata: line.metadata.to_h.except(*cleared)) if line && cleared.any?
    service = sheet.reprice!
    render json: build_json(@build.reload, service.warnings)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # A color the factory offers that the book lacks, typed on the sheet: saved
  # as the dealer's own (every sheet with that color set lists it after),
  # sent to the platform admin, and picked on this sheet.
  def create_color
    return unless authorize_action!('deals', 'update')

    Truebuild::DealBuild.assert_editable!(@build)
    color_set = params[:color_set].to_s
    offered = Truebuild::OptionSource.for_dealer(@company, Truebuild::OptionSource.current_for(@build.variant), @build.variant,
                                                 construction: @build.construction)
    set_ids = offered.select { |op| Truebuild::DealBuild.choice_set(op.option) == color_set }.map(&:catalog_option_id)
    return render json: { error: "#{color_set} is not a color set on this home" }, status: :unprocessable_entity if set_ids.empty?
    if params[:replaces_id].present? && !set_ids.include?(params[:replaces_id].to_i)
      return render json: { error: 'The color it replaces must be in the same set' }, status: :unprocessable_entity
    end

    option = Truebuild::DealerOptions.add_color!(
      company: @company, manufacturer_id: @build.variant.manufacturer_id, color_set: color_set, name: params[:name],
      factory_code: params[:factory_code], cost: params[:cost], retail: params[:retail], replaces_id: params[:replaces_id].presence,
      user: current_user, deal: @deal, note: params[:note]
    )
    service = sheet
    service.add_option(option.id)
    render json: build_json(@build.reload, service.warnings).merge(color: { id: option.id, name: option.name }), status: :created
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Drops a factory color from the dealer's lists (it stays picked where it
  # was picked) and tells the platform admin.
  def hide_color
    return unless authorize_action!('deals', 'update')

    option = CatalogOption.platform.find_by(id: params[:option_id], manufacturer_id: @build.variant.manufacturer_id)
    unless option && Truebuild::DealBuild.choice_set(option)
      return render json: { error: 'That is not a factory color for this home' }, status: :unprocessable_entity
    end

    Truebuild::DealerOptions.hide!(company: @company, option_id: option.id, user: current_user, deal: @deal, note: params[:note])
    head :no_content
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Takes the dealer's own upgrade off their list: new sheets stop offering it,
  # sheets that have it keep it. Like the rest of the list, a deal reader's to change (E85).
  def remove_upgrade
    return unless authorize_action!('deals', 'update')

    option = @company.dealer_colors.find_by(id: params[:option_id], kind: 'upgrade')
    return render json: { error: 'That upgrade is not on your list' }, status: :not_found unless option

    Truebuild::DealerOptions.remove_color!(option, user: current_user)
    head :no_content
  end

  # A cost that came in after signing (the hauler's bill): anyone who can update
  # deals records it with no new signature, as long as the buyers' price holds.
  def correct_cost
    return unless authorize_action!('deals', 'update')

    line = @build.lines.find(params[:id])
    service = Truebuild::DealBuild.new(@build)
    service.correct_signed_cost(line, params.require(:unit_cost), user: current_user)
    render json: build_json(@build.reload, service.warnings)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  rescue ActionController::ParameterMissing
    render json: { error: 'Enter the cost' }, status: :unprocessable_entity
  rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Where this deal's home really is. A catalog home gets the dealer's own copy,
  # and the deal and sheet move to it: the catalog row stays as it is.
  def home_status
    return unless authorize_action!('deals', 'update')

    Truebuild::DealBuild.assert_editable!(@build)
    vehicle = @build.vehicle
    return render json: { error: 'This sheet has no home in inventory' }, status: :unprocessable_entity unless vehicle
    return render json: { error: 'Choose a status' }, status: :unprocessable_entity unless Vehicle::STATUSES.include?(params[:status])

    if vehicle.cloneable?
      if params[:status] != vehicle.status
        clone = VehicleCloneFromCatalogService.new(vehicle, status: params[:status], attributes: { location_id: @deal.location_id }.compact).call
        return render json: { error: 'Could not make your copy of this catalog home' }, status: :unprocessable_entity unless clone

        @deal.update!(vehicle_id: clone.id) if @deal.vehicle_id == vehicle.id
        @build.update!(vehicle: clone)
      end
    else
      vehicle.update!(status: params[:status])
    end
    service = sheet.reprice!
    render json: build_json(@build.reload, service.warnings)
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def use_doc_fee
    return unless authorize_action!('deals', 'update')

    service = sheet
    service.use_dealer_doc_fee
    render json: build_json(@build.reload, service.warnings)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def truthy?(value) = ActiveModel::Type::Boolean.new.cast(value) == true

  # The LIVE sheet of a won or posted deal, unsigned: an edit corrects the deal,
  # and anyone who can update deals can make it.
  def closed_sheet? = @build&.live? && @deal.cost_snapshotted? && !@build.locked?

  def sheet
    Truebuild::DealBuild.new(@build, correcting_by: closed_sheet? ? current_user : nil)
  end

  # A correction on a posted deal also posts to the books. If that can't happen
  # (a closed period), none of it happens.
  def correction_in_one_piece
    return yield unless closed_sheet?

    ActiveRecord::Base.transaction { yield }
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    render json: { error: "This deal is approved, and the change could not be posted to the books (#{e.message}). Nothing was changed." }, status: :unprocessable_entity unless performed?
  end

  # An add-on or template's price going forward, on the dealer's own list. This
  # deal takes it too. Other sheets keep the price they have.
  def remember_list_item(line)
    Truebuild::DealBuild.assert_editable!(@build)
    source = line.kind == 'addon' ? line.truebuild_addon&.source : line.source_template
    return render json: { error: 'That is no longer on your list' }, status: :unprocessable_entity unless source

    service = sheet
    ActiveRecord::Base.transaction do
      if params.key?(:price)
        if line.kind == 'addon' then line.truebuild_addon.update!(price_override: params[:price].presence)
        elsif source.is_a?(FeeTemplate) then source.update!(default_amount: params[:price])
        else source.update!(default_price: params[:price])
        end
      end
      source.update!(cost: params[:cost]) if params.key?(:cost) && source.respond_to?(:cost=)
      line_changes = {}
      line_changes[:unit_retail] = params[:price] if params.key?(:price) && line.kind == 'template'
      line_changes[:unit_cost] = params[:cost] if params.key?(:cost)
      line.update!(line_changes) if line_changes.any?
      service.reprice!
    end
    render json: build_json(@build.reload, service.warnings)
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # The home to start from: one a price book has, or one typed by hand.
  def home_from_params
    return priced_variant(params[:variant_id]) if params[:manual_home].blank?

    m = params.require(:manual_home).permit(:description, :maker, :model, :width_ft, :length_ft, :beds, :baths, :building_code).to_h.symbolize_keys
    Truebuild::ManualHome.create!(company: @company, **m)
  end

  def type_manual_prices(service)
    return if params[:manual_home].blank?

    typed = params.require(:manual_home).permit(:price, :cost, :pack, :discount_pct, :discount_amount)
    # The rep saw these in the form, so they replace the defaults a new sheet starts with.
    service.set_discounts('savings_pct' => 0, 'sale_pct' => typed[:discount_pct].to_f, 'preferred_pct' => 0, 'other_amount' => typed[:discount_amount].to_f) if typed.key?(:discount_pct) || typed.key?(:discount_amount)
    @deal.update_columns(pack_amount: typed[:pack].to_d) if typed[:pack].present? && !@deal.cost_snapshotted?
    prices = typed.slice(:price, :cost).to_h.compact_blank
    base = service.build.lines.find_by(kind: 'base')
    service.update_line(base, { unit_retail: prices['price'], unit_cost: prices['cost'] }.compact) if base && prices.any?
  end

  # Add-ons and templates to offer. A sheet holding the dealer's document fee
  # is not offered another. Whatever moved to Addendum A, and a template the
  # same as an add-on, is not offered twice unless it is the one on this sheet.
  def addon_lists(variant)
    fee_held = @build.lines.any?(&:required_fee?)
    upgrades = @company.dealer_colors.active.where(manufacturer_id: variant.manufacturer_id, kind: 'upgrade').pluck(:name).map { |n| n.to_s.downcase }
    chosen = @build.lines.where(kind: 'template').map { |l| [l.source_template_type, l.source_template_id] }
    addons = @company.truebuild_addons.active.for_manufacturer(variant.manufacturer_id).order(:position, :id).to_a
    addons = addons.reject { |a| a.fee? && Truebuild::DealBuild.doc_fee_name?(a.name) } if fee_held
    addons = addons.reject { |a| upgrades.include?(a.name.to_s.downcase) }
    addon_names = addons.map { |a| a.name.to_s.downcase }
    templates = templates_json.reject do |t|
      next false if chosen.include?([t[:type], t[:id]])

      name = t[:name].to_s.downcase
      upgrades.include?(name) || addon_names.include?(name) || (fee_held && t[:type] == 'FeeTemplate' && Truebuild::DealBuild.doc_fee_name?(t[:name]))
    end
    [addons, templates]
  end

  # A home typed by hand has no book: the dealer's own upgrades and add-ons are its list.
  def manual_home_options
    chosen = @build.lines.where(kind: 'option').pluck(:catalog_option_id).to_set
    upgrades = @company.dealer_colors.active.where(manufacturer_id: @build.variant.manufacturer_id, kind: 'upgrade').order(:name)
    addons, templates = addon_lists(@build.variant)
    rows = upgrades.map do |o|
      { id: o.id, name: o.name, kind: 'upgrade', standard: false, dealer_color: false, dealer_upgrade: true, price: o.metadata.to_h['retail']&.to_f,
        cost: o.metadata.to_h['cost']&.to_f, suggested_retail: nil, factory_code: o.factory_code, includes: [], unit: 'each', chosen: chosen.include?(o.id), rules: [] }
    end
    { book_id: nil, book_name: nil, groups: rows.any? ? [{ id: nil, name: 'Other upgrades', selection_type: 'multiple', required: false, options: rows }] : [],
      addons: addons.map { |a| { id: a.id, name: a.name, mode: a.mode, price: a.price.to_f, cost: a.cost.to_f } }, templates: templates }
  end

  def book_row_for_option(option_id)
    variant = @build.variant
    book = @build.options_book || Truebuild::OptionSource.current_for(variant)
    return nil unless book

    most_specific(Truebuild::OptionSource.offered(book, variant, construction: @build.construction, option_ids: [option_id]).to_a).first
  end

  # The price book row that priced a line: the home's base, or the option's
  # most specific row in the book its options come from.
  def book_row_for(line)
    variant = @build.variant
    case line.kind
    when 'base'
      book = @build.cost_book || @build.price_book
      book&.variant_prices&.find_by(catalog_plan_variant_id: variant.id)
    when 'option'
      line.catalog_option_id && book_row_for_option(line.catalog_option_id)
    end
  end

  def set_deal
    deals = @company.deals
    if current_user.uses_rbac? && !current_user.effective_admin?
      ids = permission_service.accessible_location_ids
      deals = ids.any? ? deals.where(location_id: ids) : deals.none
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
    unless variant && Truebuild::HomeMatcher.new.priced?(variant.id)
      render json: { error: 'That model is not in a published price book. You can type the home in by hand.' }, status: :unprocessable_entity
      return nil
    end
    # The factories a platform admin gave this dealer, as the model list shows. A home of theirs on the lot is theirs to sell.
    given = @company.dealer_factories.pluck(:factory_id)
    if given.any? && given.exclude?(variant.catalog_plan&.factory_id) && !@company.vehicles.exists?(catalog_plan_variant_id: variant.id)
      render json: { error: 'That model is not from a factory on your account' }, status: :unprocessable_entity
      return nil
    end
    variant
  end

  def offered_option?(option_id)
    if @build.variant.manual_home?
      return @company.dealer_colors.active.exists?(id: option_id, manufacturer_id: @build.variant.manufacturer_id, kind: 'upgrade')
    end

    book = Truebuild::OptionSource.current_for(@build.variant)
    Truebuild::OptionSource.for_dealer(@company, book, @build.variant, construction: @build.construction)
                           .any? { |op| op.catalog_option_id == option_id.to_i }
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
                         suggestions: vehicle.catalog_plan_variant_id ? [] : matcher.suggest(vehicle),
                         inventory: vehicle.catalog_plan_variant_id ? nil : Truebuild::StandAlonePricing.inventory_figures(vehicle) },
      typed_defaults: Truebuild::StandAlonePricing.new(@company, location: @deal.location).defaults,
      designs: designs.map { |d| { design_id: d.id, name: d.name, buyer_name: d.buyer_name, model: matcher.variant_json(d.variant), saved_at: d.created_at } }
    }
  end

  def build_json(build, warnings = nil)
    variant = build.variant
    { build: {
      id: build.id, deal_id: build.deal_id, status: build.status, source: build.source, construction: build.construction,
      notes: build.notes, priced_at: build.priced_at,
      version_number: build.version_number, label: build.label, live: build.live, version_name: build.version_name,
      last_unlock: Array(build.metadata.to_h['unlocks']).last,
      out_for_signature: (out = Agreements::DealSheetLock.out_for_signature(build)) && { id: out.id, number: out.agreement_number, status: out.status },
      versions: versions_json(build.deal),
      specs_set: build.metadata.to_h['home_specs'].to_h.compact_blank.keys,
      model: model_json(variant, Truebuild::HomeMatcher.new).merge(specs_for_json(build)).merge(factory: variant.catalog_plan.factory&.name,
                                                                   series: variant.manual_home? ? nil : variant.catalog_plan.series,
                                                                   model_number: variant.shown_model_number),
      vehicle: build.vehicle && { id: build.vehicle.id, stock_number: build.vehicle.stock_number, status: build.vehicle.status, on_lot: build.vehicle.on_lot?,
                                  title: [build.vehicle.year, build.vehicle.make, build.vehicle.model].compact.join(' ') },
      design_id: build.truebuild_design_id,
      deal_terms: { delivery_point: @deal.try(:delivery_point), delivery_street: @deal.delivery_street,
                    delivery_city: @deal.delivery_city, delivery_state: @deal.delivery_state,
                    delivery_zip: @deal.delivery_zip, location_state: @deal.location&.state },
      books: { base: build.price_book&.name, cost: build.cost_book&.name, options: build.options_book&.name, cost_id: build.cost_book_id },
      totals: build.totals,
      discounts: build.discounts,
      freight_miles_set: build.freight_miles_set,
      # The dealer's document fee setting, nil until set. Line 6 is read only only on a sheet that took it.
      doc_fee: DealerCatalogTerm.effective(@company, variant.manufacturer_id).doc_fee&.to_f,
      color_skips: build.color_skips,
      # Lines on the deal the sheet did not write (a warranty added in Products).
      other_deal_lines: other_deal_lines(build),
      warnings: [*(warnings || build.totals['warnings'] || []), *unapplied_signatures(build)].uniq,
      manual_home: variant.manual_home?,
      # What this person can do here, so the screen can say so before they try.
      can: { edit: can?('deals', 'update'), unlock: can?('agreements', 'delete'), create_po: can?('inventory', 'create'),
             override_fee: current_user.effective_admin? },
      closed: build.live? && build.deal.cost_snapshotted? && !build.locked?,
      purchase_orders: build.deal.purchase_orders.where(kind: 'factory_home', is_deleted: [false, nil]).order(:created_at)
                            .map { |po| purchase_order_json(po) },
      lines: build.lines.includes(:option).map { |l| line_json(l) }
    } }
  end

  # Buyers signed and the deal did not change: every open of the sheet says so until it is sorted out.
  def unapplied_signatures(build)
    return [] unless build.live?

    @company.agreements.where(deal_id: build.deal_id, status: Agreement::STATUS_COMPLETED).where("metadata ? 'deal_sheet_not_applied'")
            .map { |a| "#{a.agreement_number}: #{a.metadata.dig('deal_sheet_not_applied', 'reason')}" }
  end

  def specs_for_json(build)
    s = build.specs
    { beds: s['beds']&.to_i, baths: s['baths']&.to_f, width_ft: s['width_ft']&.to_i, length_ft: s['length_ft']&.to_i, square_feet: s['square_feet']&.to_i }.compact
  end

  def line_json(l)
    { id: l.id, kind: l.kind, option_id: l.catalog_option_id, addon_id: l.truebuild_addon_id, group: l.group_name, label: l.label,
      factory_code: l.factory_code, quantity: l.quantity.to_f, unit: l.unit, unit_cost: l.unit_cost&.to_f, unit_retail: l.unit_retail&.to_f,
      cost: l.cost&.to_f, retail: l.retail&.to_f, standard: l.is_standard, tbd: l.tbd, no_charge: l.no_charge,
      tax_category: l.tax_category, set_retail: l.metadata['set_retail'] == true, set_cost: l.metadata['set_cost'] == true, set_surcharge: l.metadata.key?('set_surcharge'), not_offered: l.metadata['not_offered'] == true,
      from_products: l.metadata['from_products'] == true,
      dealer_cost_set: l.metadata['dealer_cost_set'] == true, book_name: l.metadata['book_name'],
      dealer_color: l.option&.dealer_color? == true && !l.option.dealer_upgrade?, dealer_upgrade: l.option&.dealer_upgrade? == true,
      factory_order: l.option&.dealer_upgrade? ? l.option.metadata.to_h['factory_order'] != false : nil,
      color_set: l.option && Truebuild::DealBuild.choice_set(l.option),
      free_color: Truebuild::AgreementSheets.free_color?(l),
      required_fee: l.required_fee?,
      fee_locked: l.required_fee? && !current_user.effective_admin?,
      doc_fee_line: l.required_fee? || (l.tax_category == 'fee' && Truebuild::DealBuild.doc_fee_name?(l.label)),
      rule: l.metadata['rule'], notes: l.metadata['notes'], base: l.metadata['base'], freight: l.metadata['freight'],
      template_type: l.source_template_type, template_id: l.source_template_id,
      # What a package holds ("PACKAGE 2" alone says nothing to a buyer).
      includes: l.kind == 'option' ? Array(l.option&.package_items).map(&:to_s) : [] }
  end

  def purchase_order_json(po)
    { id: po.id, po_number: po.po_number, status: po.status, total: po.total_amount.to_f, supplier: po.supplier&.name,
      version_number: po.sheet_snapshot.to_h['version'], changed_since: Truebuild::FactoryOrder.changed?(po),
      kept: Truebuild::FactoryOrder.kept_info(po),
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
