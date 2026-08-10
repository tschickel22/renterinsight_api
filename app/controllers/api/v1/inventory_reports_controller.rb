# frozen_string_literal: true

class Api::V1::InventoryReportsController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/inventory/reports/stock_list
  # Read-only Inventory Stock List & GP Snapshot. Cost/GP columns are gated by
  # deals:read:view_cost_details (mirrors deals_controller#deal_json).
  #
  # Gated on inventory_reports rather than deals: this is an inventory report,
  # and riding on the deals key meant anyone who could see a deal could see the
  # whole stock list.
  def stock_list
    return unless authorize_action!('inventory_reports', 'read')

    # Mirror deals_controller#deal_json cost gate exactly.
    can_view_costs = current_user&.has_permission?('deals', 'read', scope: 'view_cost_details') || false

    report = Reports::InventoryStockReportService.new(@company, current_user: current_user).generate(
      scope: params[:scope].presence || 'inventory',
      can_view_costs: can_view_costs,
      filters: report_filters
    )

    render json: report
  end

  # GET /api/v1/inventory/reports/salesperson_gp_pipeline
  # Read-only Salesperson GP Pipeline ("Cheat Sheet"). Cost/GP columns AND the GP summary
  # are gated by deals:read:view_cost_details (mirrors deals_controller#deal_json).
  #
  # A sales-management report, so it answers to sales_reports. The cost gate
  # below is unchanged and still decides whether the GP columns render.
  def salesperson_gp_pipeline
    return unless authorize_action!('sales_reports', 'read')

    can_view_costs = current_user&.has_permission?('deals', 'read', scope: 'view_cost_details') || false

    report = Reports::SalespersonGpPipelineReportService.new(@company, current_user: current_user).generate(
      scope: params[:scope].presence || 'inventory',
      can_view_costs: can_view_costs,
      filters: report_filters
    )

    render json: report
  end

  private

  def report_filters
    permitted = params.permit(
      :location_id, :section, :status, :salesperson_id, :lender, :aging_bucket, :search,
      :funded_group_by, :closed_from, :closed_to,
      statuses: []
    ).to_h.symbolize_keys
    # Also accept a comma-separated string form of statuses.
    permitted[:statuses] = params[:statuses] if permitted[:statuses].blank? && params[:statuses].is_a?(String)
    permitted
  end
end
