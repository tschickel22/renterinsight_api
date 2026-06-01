# frozen_string_literal: true

class Api::V1::InventoryReportsController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/inventory/reports/stock_list
  # Read-only Inventory Stock List & GP Snapshot. Cost/GP columns are gated by
  # deals:read:view_cost_details (mirrors deals_controller#deal_json).
  def stock_list
    return unless authorize_action!('deals', 'read')

    # Mirror deals_controller#deal_json cost gate exactly.
    can_view_costs = current_user&.has_permission?('deals', 'read', scope: 'view_cost_details') || false

    report = Reports::InventoryStockReportService.new(@company, current_user: current_user).generate(
      scope: params[:scope].presence || 'inventory',
      can_view_costs: can_view_costs,
      filters: report_filters
    )

    render json: report
  end

  private

  def report_filters
    params.permit(
      :location_id, :section, :status, :salesperson_id, :lender, :aging_bucket, :search
    ).to_h.symbolize_keys
  end
end
