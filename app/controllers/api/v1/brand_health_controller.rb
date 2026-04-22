# frozen_string_literal: true

class Api::V1::BrandHealthController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/brand-health
  def show
    return unless authorize_action!('social_posts', 'read')

    begin
      data = BrandHealthService.fetch_for_company(@company)
    rescue MetaGraphApi::ExpiredTokenError
      return render json: { error: 'Facebook token expired. Please reconnect.' }, status: :unprocessable_entity
    rescue MetaGraphApi::Error => e
      return render json: { error: "Meta API error: #{e.message}" }, status: :bad_gateway
    end

    if data
      render json: data
    else
      render json: { error: 'No Facebook page connected' }, status: :not_found
    end
  end
end
