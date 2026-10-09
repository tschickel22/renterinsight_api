# frozen_string_literal: true

# The Deal Sheet's sections 4 (Buyer and site) and 5 (Contract): what the
# contract needs beyond the price (DealSaleDetails).
#
#   GET   /api/v1/deals/:deal_id/sale_details
#   PATCH /api/v1/deals/:deal_id/sale_details   { site_ownership, contingency, ..., payment_type, lender_id, delivery_* }
class Api::V1::DealSaleDetailsController < ApplicationController
  before_action :set_company_scope
  before_action :set_deal

  def show
    return unless authorize_action!('deals', 'read')

    render json: DealSaleDetails.new(@deal).as_json
  end

  def update
    return unless authorize_action!('deals', 'update')

    permitted = params.permit(*DealSaleDetails::FIELDS.keys, *DealSaleDetails::DEAL_FIELDS).to_h
    render json: DealSaleDetails.new(@deal).update!(permitted).as_json
  rescue DealSaleDetails::Invalid, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_deal
    @deal = @company.deals.find_by(id: params[:deal_id])
    render json: { error: 'Deal not found' }, status: :not_found unless @deal
  end
end
