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

  before_action :authenticate_inventory_token

  def home
    vehicle = @company.vehicles.where(is_deleted: [false, nil]).find_by(id: params[:vehicle_id])
    return render json: { error: 'Home not found' }, status: :not_found unless vehicle

    variant = vehicle.catalog_plan_variant
    return not_designable unless Truebuild::BuyerCatalog.available?(@company, variant)

    render json: Truebuild::BuyerCatalog.new(@company, variant, vehicle: vehicle).call.merge(vehicle_id: vehicle.id)
  end

  # GET /public/truebuild/models   Every model this dealer offers, for a site block.
  def models
    render json: { models: Truebuild::ModelList.new(@company).call(manufacturer_id: params[:manufacturer_id].presence) }
  end

  def model
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return not_designable unless Truebuild::BuyerCatalog.available?(@company, variant)

    render json: Truebuild::BuyerCatalog.new(@company, variant).call
  end

  # GET /public/truebuild/models/:variant_id/trueview
  # The model's photos with a layer per finish drawn so far. The first visit
  # queues the rest in the background; poll while drawing is above zero.
  def trueview
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return not_designable unless Truebuild::BuyerCatalog.available?(@company, variant)

    buyer = Truebuild::Trueview::Buyer.new(@company, variant)
    buyer.predraw!
    render json: buyer.call
  end

  def price
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return not_designable unless Truebuild::BuyerCatalog.available?(@company, variant)

    render json: Truebuild::BuyerCatalog.new(@company, variant, location: vehicle&.location).price(params[:option_ids], params[:addon_ids])
  end

  def create_design
    variant = CatalogPlanVariant.find_by(id: params[:variant_id])
    return not_designable unless Truebuild::BuyerCatalog.available?(@company, variant)
    return render json: { error: 'Please try again' }, status: :unprocessable_entity if params[:website].present? # honeypot
    return render json: { error: 'Too many saves. Please try again later.' }, status: :too_many_requests if throttled?

    design = Truebuild::DesignSaver.new(
      company: @company, variant: variant, vehicle: vehicle, option_ids: params[:option_ids], addon_ids: params[:addon_ids],
      contact: params.fetch(:contact, {}).permit(:first_name, :last_name, :email, :phone, :message, :marketing_consent).to_h,
      context: params.fetch(:context, {}).permit(:page_url, :utm_source, :utm_medium, :utm_campaign, :utm_content, :utm_term).to_h,
      request: request
    ).call
    render json: design_json(design), status: :created
  rescue Truebuild::DesignSaver::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def show_design
    design = @company.truebuild_designs.find_by(public_token: params[:design_token])
    return render json: { error: 'Design not found' }, status: :not_found unless design

    design.record_view! unless params[:preview].present?
    render json: design_json(design)
  end

  private

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
    token = params[:token] || request.headers['X-Inventory-Token']
    @company = token.present? && Company.find_by(public_inventory_token: token)
    return render json: { error: 'Invalid inventory token' }, status: :unauthorized unless @company

    render json: { error: 'Public inventory access is disabled' }, status: :forbidden unless @company.public_inventory_enabled
  end
end
