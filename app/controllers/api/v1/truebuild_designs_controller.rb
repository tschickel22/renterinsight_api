# frozen_string_literal: true

# Homes buyers designed and saved, for the rep: what they chose, the price
# they were shown, what it would cost today, and whether the share link is
# being opened.
class Api::V1::TruebuildDesignsController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/truebuild_designs?lead_id=
  def index
    return unless authorize_action!('leads', 'read')

    designs = @company.truebuild_designs.includes(variant: :catalog_plan, vehicle: []).order(created_at: :desc)
    designs = designs.where(lead_id: params[:lead_id]) if params[:lead_id].present?
    render json: { designs: designs.limit(50).map { |d| design_json(d) } }
  end

  private

  def design_json(d)
    names = CatalogOption.where(id: d.option_ids).pluck(:id, :name).to_h
    shown = d.price_snapshot['show_prices'] ? d.price_snapshot['total'] : nil
    {
      id: d.id, name: d.name, status: d.status, created_at: d.created_at,
      buyer_name: d.buyer_name, lead_id: d.lead_id, vehicle_id: d.vehicle_id, stock_number: d.vehicle&.stock_number,
      options: d.option_ids.filter_map { |id| names[id] },
      price_shown: shown, price_today: price_today(d),
      view_count: d.view_count, last_viewed_at: d.last_viewed_at,
      link: Truebuild::DesignSaver.design_url(d)
    }
  end

  # The same home and options at today's prices, so a rep sees an increase
  # before the buyer does.
  def price_today(d)
    Truebuild::PricingEngine.new(company: @company, variant: d.variant, option_ids: d.option_ids,
                                 location: d.vehicle&.location).call.totals[:retail]
  rescue ArgumentError
    nil
  end
end
