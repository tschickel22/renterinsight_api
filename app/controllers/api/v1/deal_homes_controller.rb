# frozen_string_literal: true

# The real home on a deal: its serial number or VIN, typed on the deal or on
# its Deal Sheet (DealHomeLink#assign_serial!).
#
#   GET  /api/v1/deals/:deal_id/home         the deal's home and a factory PO the serial could receive
#   POST /api/v1/deals/:deal_id/home/serial  { serial_number?, vin?, status?, stock_number?, use_existing_id?, receive_po? }
#
# A serial already on another home answers 409 with that home, so the screen can
# offer to link it (use_existing_id) instead of making the same home twice.
class Api::V1::DealHomesController < ApplicationController
  before_action :set_company_scope
  before_action :set_deal

  def show
    return unless authorize_action!('deals', 'read')

    render json: home_json
  end

  def serial
    return unless authorize_action!('deals', 'update')

    want_receive = ActiveModel::Type::Boolean.new.cast(params[:receive_po])
    return unless !want_receive || authorize_action!('inventory', 'update')

    build = @deal.home_build
    link = DealHomeLink.new(@deal, build: build)
    home = nil
    received = nil
    ActiveRecord::Base.transaction do
      home = link.assign_serial!(serial_number: params[:serial_number], vin: params[:vin], status: params[:status].presence,
                                 stock_number: params[:stock_number], use_existing_id: params[:use_existing_id])
      if want_receive && (po = link.receivable_purchase_order)
        Truebuild::FactoryOrder.receive!(po, serial_number: home.serial_number, vehicle: home, user: current_user)
        received = po.reload.po_number
      end
    end
    reprice(build.reload) if build
    render json: home_json.merge(received_po: received)
  rescue DealHomeLink::Duplicate => e
    v = e.vehicle
    render json: { error: e.message, existing: vehicle_json(v) }, status: :conflict
  rescue DealHomeLink::Refused, Truebuild::FactoryOrder::Refused, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  # The sheet follows the home's status (on the lot or to order) while the deal is open.
  def reprice(build)
    return unless build.live? && !@deal.cost_snapshotted? && Agreements::DealSheetLock.edit_problem(build).nil?

    Truebuild::DealBuild.new(build).reprice!
  rescue StandardError => e
    Rails.logger.warn("[DealHomes] deal #{@deal.id} reprice after serial: #{e.message}")
  end

  def home_json
    @deal.reload
    vehicle = @deal.vehicle
    po = DealHomeLink.new(@deal, build: @deal.home_build).receivable_purchase_order
    { home: vehicle && vehicle_json(vehicle), has_sheet: @deal.home_build.present?,
      receivable_purchase_order: po && { id: po.id, po_number: po.po_number, status: po.status } }
  end

  def vehicle_json(v)
    { id: v.id, title: DealHomeLink.title(v), status: v.status, serial_number: DealHomeLink.real_serial(v),
      vin: DealHomeLink.real_vin(v), stock_number: v.stock_number, available_to_order: v.catalog_row?,
      deal_ids: @company.deals.active.where(vehicle_id: v.id).pluck(:id) }
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
end
