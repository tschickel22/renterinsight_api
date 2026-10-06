# frozen_string_literal: true

# Homes on a dealer's lot linked to the TrueBuild model they are. A linked
# home that is not built yet (to order, ordered, on order) opens the designer
# from its listing; a linked home without photos of its own shows the
# manufacturer's. A home whose model text carries a priced model number
# links itself on save; one entered by hand ("56' Bay Port") carries none,
# so the dealer links it here, from suggestions.
class Api::V1::TruebuildHomesController < ApplicationController
  include ModuleAccessRequired
  require_module! Truebuild::BuyerCatalog::MODULE
  before_action :set_company_scope

  STATUSES = (Truebuild::BuyerCatalog::DESIGNABLE_STATUSES + %w[available]).freeze

  # GET /api/v1/truebuild_homes
  def index
    return unless authorize_action!('inventory', 'read')

    catalog = Truebuild::HomeMatcher.new
    vehicles = scoped_vehicles.includes(catalog_plan_variant: :catalog_plan).order(:status, :model).limit(500).to_a
    ready = Truebuild::ModelList.trueview_ready(vehicles.filter_map(&:catalog_plan_variant_id).uniq)
    homes = vehicles.map do |v|
      # Used homes and builders no book prices get no model picker.
      covered = catalog.coverable?(v)
      { id: v.id, title: [v.year, v.make, v.model].compact.join(' '), status: v.status, stock_number: v.stock_number,
        designable: Truebuild::BuyerCatalog::DESIGNABLE_STATUSES.include?(v.status),
        trueview: ready.include?(v.catalog_plan_variant_id),
        covered: covered,
        linked: v.catalog_plan_variant && catalog.variant_json(v.catalog_plan_variant),
        suggestions: v.catalog_plan_variant_id || !covered ? [] : catalog.suggest(v) }
    end
    render json: { homes: homes }
  end

  # PATCH /api/v1/truebuild_homes/:id { variant_id }   (null unlinks)
  def update
    return unless authorize_action!('inventory', 'update')

    vehicle = scoped_vehicles.find_by(id: params[:id])
    return render json: { error: 'Not found' }, status: :not_found unless vehicle

    variant_id = params[:variant_id].presence&.to_i
    if variant_id && !Truebuild::HomeMatcher.new.priced?(variant_id)
      return render json: { error: 'That model is not in a published price book' }, status: :unprocessable_entity
    end

    vehicle.update_columns(catalog_plan_variant_id: variant_id, updated_at: Time.current)
    render json: { id: vehicle.id, variant_id: variant_id }
  end

  private

  def scoped_vehicles
    vehicles = @company.vehicles.where(is_deleted: [false, nil], status: STATUSES)
    if current_user.uses_rbac? && !current_user.effective_admin?
      ids = @company.expand_with_inventory_peers(permission_service.accessible_location_ids)
      vehicles = ids.any? ? vehicles.where(location_id: ids) : vehicles.none
    end
    vehicles = vehicles.where(location_id: Current.location_id) if Current.location_filtered?
    vehicles
  end
end
