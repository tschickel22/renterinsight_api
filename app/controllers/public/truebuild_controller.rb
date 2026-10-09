# frozen_string_literal: true

# TrueBuild on a dealer's website: design a home, see the dealer's price, save
# it. Same public inventory token as the home pages (Public::InventoryController);
# a buyer only ever sees retail, never cost.
#
#   GET  /public/truebuild/homes/:vehicle_id   design data for a home on the lot
#   GET  /public/truebuild/models/:variant_id  design data for a catalog model
#   GET  /public/truebuild/models/:variant_id/trueview  finish layers for the model's photos
#   POST /public/truebuild/price               { variant_id, option_ids }
#   POST /public/truebuild/designs             { variant_id, vehicle_id, option_ids, contact, context }
#   GET  /public/truebuild/designs/:design_token      a saved design, for its share link
class Public::TruebuildController < ApplicationController
  skip_before_action :authenticate, raise: false
  skip_before_action :set_company_scope, raise: false
  skip_before_action :set_current_attributes, raise: false

  include TruebuildReach

  before_action :authenticate_inventory_token
  before_action :require_truebuild_reach

  def home
    vehicle = @company.vehicles.where(is_deleted: [false, nil]).find_by(id: params[:vehicle_id])
    return render json: { error: 'Home not found' }, status: :not_found unless vehicle

    variant = vehicle.catalog_plan_variant
    return not_designable unless Truebuild::BuyerCatalog.designable_home?(@company, vehicle)

    render json: Truebuild::BuyerCatalog.new(@company, variant, vehicle: vehicle).for_buyer.merge(vehicle_id: vehicle.id)
  end

  # GET /public/truebuild/models   Every model this dealer offers, for a site block.
  #   factory_ids[], series[]: only those. trueview_only: only models with TrueView drawn.
  #   facets=1: also the factories and series there are, for the block's settings.
  def models
    return render json: { models: [] } unless @company.has_module?(Truebuild::BuyerCatalog::MODULE)

    list = Truebuild::ModelList.new(@company)
    body = { models: list.call(manufacturer_id: params[:manufacturer_id].presence, factory_ids: params[:factory_ids],
                               series: params[:series], trueview_only: ActiveModel::Type::Boolean.new.cast(params[:trueview_only])) }
    body[:facets] = list.facets(manufacturer_id: params[:manufacturer_id].presence) if params[:facets].present?
    render json: body
  end

  def model
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return not_designable unless designable_model?(variant)

    render json: Truebuild::BuyerCatalog.new(@company, variant, show_prices: @preview == true).for_buyer
  end

  # GET /public/truebuild/models/:variant_id/trueview
  # The model's photos with a layer per finish drawn so far; poll while
  # drawing (a factory run's) is above zero.
  def trueview
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return not_designable unless designable_model?(variant)

    # Asked every 20 seconds while a factory run draws, from every open
    # designer: answered from a 15 second cache. A visit draws nothing; only
    # factory runs do (Buyer#queue_missing!).
    body = Rails.cache.fetch("truebuild:trueview:buyer:#{@company.id}:#{variant.id}", expires_in: 15.seconds) do
      Truebuild::Trueview::Buyer.new(@company, variant).call
    end
    render json: body
  end

  def price
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return not_designable unless designable_model?(variant)

    render json: Truebuild::BuyerCatalog.new(@company, variant, location: vehicle&.location, show_prices: @preview == true)
                                       .price(params[:option_ids], params[:addon_ids])
  end

  def create_design
    return render json: { error: 'This is a preview: designs are not saved' }, status: :forbidden if @preview
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return not_designable unless designable_model?(variant)
    return render json: { error: 'Please try again' }, status: :unprocessable_entity if params[:website].present? # honeypot
    return render json: { error: 'Too many saves. Please try again later.' }, status: :too_many_requests if throttled?

    design = Truebuild::DesignSaver.new(
      company: @company, variant: variant, vehicle: vehicle, option_ids: params[:option_ids], addon_ids: params[:addon_ids],
      contact: params.fetch(:contact, {}).permit(:first_name, :last_name, :email, :phone, :message, :marketing_consent).to_h,
      context: params.fetch(:context, {}).permit(:page_url, :utm_source, :utm_medium, :utm_campaign, :utm_content, :utm_term).to_h,
      request: request, copied_from: params[:copied_from],
      buyer_access: Truebuild::BuyerPass.resolve(params[:as], @company)
    ).call
    # Saving another version asks for nothing again: the pass the buyer came
    # with, or one naming who just saved.
    pass = params[:as].presence if Truebuild::BuyerPass.resolve(params[:as], @company)
    render json: design_json(design).merge(pass: pass || Truebuild::BuyerPass.issue_for_design(design)), status: :created
  rescue Truebuild::DesignSaver::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /public/truebuild/designs/:design_token/events { type: 'shared' }
  # The buyer shared their design (share sheet or copied link). Counted and
  # raised for follow up; a few per hour per address at most.
  def design_event
    design = @company.truebuild_designs.find_by(public_token: params[:design_token])
    return render json: { error: 'Design not found' }, status: :not_found unless design
    return head :no_content unless params[:type].to_s == 'shared'

    key = "truebuild:design:shared:#{design.id}:#{request.remote_ip}"
    design.track!('shared') if Rails.cache.write(key, true, expires_in: 10.minutes, unless_exist: true)
    head :no_content
  end

  # GET /public/truebuild/buyer?as=
  # Who a My Designs link belongs to, so the designer can say "Saving to
  # Tia's account" and skip the contact form.
  def buyer
    access = Truebuild::BuyerPass.resolve(params[:as], @company)
    return render json: { signed_in: false } unless access

    render json: { signed_in: true, first_name: access.buyer.try(:first_name), email: access.email }
  end

  def show_design
    design = @company.truebuild_designs.find_by(public_token: params[:design_token])
    return render json: { error: 'Design not found' }, status: :not_found unless design

    design.record_view! unless params[:preview].present?
    render json: design_json(design)
  end

  private

  # On the dealer's own website, only with the add-on (TruebuildReach).
  def require_truebuild_reach
    return if @preview || truebuild_reachable?

    render json: { error: 'Design this home on our website', design_url: truebuild_site_url }.compact, status: :forbidden
  end

  def vehicle
    return @vehicle if defined?(@vehicle)

    @vehicle = params[:vehicle_id].present? ? @company.vehicles.find_by(id: params[:vehicle_id]) : nil
  end

  # A buyer saves a design or two; a script saves hundreds. Ten an hour per
  # address per dealer is plenty for a family on one connection.
  def throttled?
    key = "truebuild:saves:#{@company.id}:#{request.remote_ip}"
    count = Rails.cache.increment(key, 1, expires_in: 1.hour) || Rails.cache.write(key, 1, expires_in: 1.hour) && 1
    count.to_i > 10
  end

  # A platform admin's Preview as a buyer (Truebuild::PreviewPass): the
  # dealer it prices through, that factory's models only.
  def authenticate_preview
    pass = Truebuild::PreviewPass.resolve(params[:preview])
    return false unless pass

    @company = Company.find_by(id: pass['company_id'])
    return false unless @company

    @preview = true
    @preview_factory_id = pass['factory_id']
    true
  end

  # In a preview, any model of the factory a published book prices, released
  # or not; otherwise what the dealer offers buyers.
  def designable_model?(variant)
    return Truebuild::BuyerCatalog.available?(@company, variant) unless @preview

    variant.present? && variant.catalog_plan&.factory_id == @preview_factory_id && Truebuild::BookResolver.current_for(variant).present?
  end

  def not_designable
    render json: { error: 'This home cannot be designed online' }, status: :not_found
  end

  # What the buyer and anyone they share with see: never cost, never the lead.
  def design_json(design)
    snap = design.price_snapshot
    { token: design.public_token, name: design.name, variant_id: design.catalog_plan_variant_id,
      vehicle_id: design.vehicle_id, option_ids: design.option_ids, addon_ids: Array(design.metadata['addon_ids']),
      created_at: design.created_at,
      price: snap['show_prices'] ? { total: snap['total'], lines: snap['lines'], priced_at: snap['priced_at'] } : nil }
  end

  def authenticate_inventory_token
    return if authenticate_preview

    token = params[:token] || request.headers['X-Inventory-Token']
    @company = token.present? && Company.find_by(public_inventory_token: token)
    return render json: { error: 'Invalid inventory token' }, status: :unauthorized unless @company

    render json: { error: 'Public inventory access is disabled' }, status: :forbidden unless @company.public_inventory_enabled
  end
end
