# frozen_string_literal: true

class Api::V1::DealAccountingController < ApplicationController
  before_action :set_company_scope
  before_action :set_deal

  # GET /api/v1/deals/:deal_id/accounting
  def show
    return unless authorize_action!('accounting', 'read')

    service = Accounting::DealAccountingService.new(@deal)
    render json: service.profitability_summary
  end

  # POST /api/v1/deals/:deal_id/accounting/calculate
  def calculate
    return unless authorize_action!('accounting', 'update')

    service = Accounting::DealAccountingService.new(@deal)
    result = service.calculate_profitability!
    render json: result
  end

  # POST /api/v1/deals/:deal_id/accounting/post_closing
  def post_closing
    return unless authorize_action!('accounting', 'create')

    service = Accounting::DealAccountingService.new(@deal)
    result = service.post_closing_entries!(user: current_user)

    if result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      render json: result
    end
  end

  private

  def set_deal
    @deal = @company.deals.find(params[:deal_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Deal not found' }, status: :not_found
  end
end
