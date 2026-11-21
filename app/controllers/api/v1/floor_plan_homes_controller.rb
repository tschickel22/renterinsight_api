# frozen_string_literal: true

# Floor plan homes (2026-11-20): every home on floor plan, the in-stock homes
# that are not, and starting, changing or stopping tracking from one list.
# Writes the same vehicle fields as the home's own Floor Plan section.
class Api::V1::FloorPlanHomesController < ApplicationController
  include AccountingLocationScoping

  before_action :set_company_scope
  before_action :set_vehicle, only: %i[update destroy]

  MAX_AT_ONCE = 200

  # GET /api/v1/accounting/floor_plan_homes
  def index
    return unless authorize_read!

    render json: service.overview
  end

  # GET /api/v1/accounting/floor_plan_homes/summary
  def summary
    return unless authorize_read!

    render json: service.summary.merge(defaults: service.defaults)
  end

  # POST /api/v1/accounting/floor_plan_homes  { homes: [{ vehicle_id, amount, rate, lender, start_date }] }
  def create
    return unless authorize_action!('inventory', 'update')

    rows = Array(params[:homes]).map { |h| h.permit(:vehicle_id, :amount, :rate, :lender, :start_date, :catch_up).to_h }
    return render(json: { error: 'Choose at least one home.' }, status: :unprocessable_entity) if rows.empty?
    return render(json: { error: "Track up to #{MAX_AT_ONCE} homes at a time." }, status: :unprocessable_entity) if rows.size > MAX_AT_ONCE

    vehicles = scoped_vehicles.where(id: rows.map { |r| r['vehicle_id'] }).index_by(&:id)
    results = rows.map do |row|
      vehicle = vehicles[row['vehicle_id'].to_i]
      next { vehicle_id: row['vehicle_id'], ok: false, error: 'Home not found.' } unless vehicle

      result = service.save(vehicle, row.except('vehicle_id'))
      { vehicle_id: vehicle.id, ok: result.ok, error: result.error, posted: result.posted.to_f, note: result.note }
    end

    saved = results.count { |r| r[:ok] }
    render json: { saved: saved, failed: results.reject { |r| r[:ok] }, results: results,
                   posted_total: results.sum { |r| r[:posted].to_f }.round(2), notes: results.filter_map { |r| r[:note] }.uniq },
           status: saved.zero? ? :unprocessable_entity : :ok
  end

  # PATCH /api/v1/accounting/floor_plan_homes/:id  { amount, rate, lender, start_date }
  def update
    return unless authorize_action!('inventory', 'update')

    result = service.save(@vehicle, params.permit(:amount, :rate, :lender, :start_date, :catch_up).to_h)
    if result.ok
      render json: { ok: true, posted: result.posted.to_f, note: result.note }
    else
      render json: { error: result.error }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/accounting/floor_plan_homes/:id  (stop tracking, no payoff recorded)
  def destroy
    return unless authorize_action!('inventory', 'update')

    result = service.stop(@vehicle)
    if result.ok
      render json: { ok: true }
    else
      render json: { error: result.error }, status: :unprocessable_entity
    end
  end

  private

  # Inventory readers, and anyone who could open the Floor Plan report before
  # this list replaced it.
  def authorize_read!
    return true if can?('inventory', 'read') || can?('inventory_reports', 'read') || can?('financial_reports', 'read')

    render json: { error: 'Access denied', required_permission: 'inventory:read OR inventory_reports:read' }, status: :forbidden
    false
  end

  def service
    @service ||= Accounting::FloorPlanHomes.new(@company, scope: scoped_vehicles)
  end

  def scoped_vehicles
    @scoped_vehicles ||= begin
      records = @company.vehicles
      if current_user.uses_rbac? && !current_user.effective_admin?
        location_ids = @company.expand_with_inventory_peers(permission_service.accessible_location_ids)
        records = location_ids.any? ? records.where(location_id: location_ids) : records.none
      end
      location = params[:location_id].presence || accounting_location_id
      location ? records.where(location_id: location) : records
    end
  end

  def set_vehicle
    @vehicle = scoped_vehicles.where(is_deleted: false).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end
end
