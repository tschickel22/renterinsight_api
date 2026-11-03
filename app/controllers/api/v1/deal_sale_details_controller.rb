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
    # What sets the price is fixed once the buyers sign (or while they are
    # signing). What comes later without changing the price stays open: the
    # home's identity, the lender and its approval, dates, the site's details.
    problem = @deal.home_build && Agreements::DealSheetLock.edit_problem(@deal.home_build)
    if problem && (permitted.keys - AFTER_SIGNING).any?
      return render json: { error: problem }, status: :conflict
    end

    render json: DealSaleDetails.new(@deal).update!(permitted).as_json
  rescue DealSaleDetails::Invalid, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  AFTER_SIGNING = %w[hud_labels model_year loan_type loan_officer approval_date approval_expires estimated_completion
                     payment_type lender_id down_payment_due_date deposit_received_on balance_due_by payment_method
                     county community_name lot_number landlord].freeze

  private

  def set_deal
    @deal = @company.deals.find_by(id: params[:deal_id])
    render json: { error: 'Deal not found' }, status: :not_found unless @deal
  end
end
