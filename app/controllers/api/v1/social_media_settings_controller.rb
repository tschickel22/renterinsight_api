# frozen_string_literal: true

class Api::V1::SocialMediaSettingsController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/social-media-settings
  def show
    return unless authorize_action!('social_posts', 'read')

    render json: SocialMediaSettingsService.for_company(@company, location_id: current_location_id)
  end

  # PATCH /api/v1/social-media-settings
  def update
    return unless authorize_action!('social_posts', 'update')

    scope_type = params[:scope_type].presence || 'Company'
    scope_id   = params[:scope_id].presence || scope_id_for(scope_type)

    return render json: { error: 'scope_id required' }, status: :bad_request if scope_id.blank?
    return render json: { error: "Unsupported scope_type '#{scope_type}'" }, status: :bad_request unless %w[Company Location].include?(scope_type)

    if scope_type == 'Location' && !@company.locations.exists?(id: scope_id)
      return render json: { error: 'Location not in this company' }, status: :forbidden
    end

    attrs = params.require(:settings).to_unsafe_h

    SocialMediaSettingsService.update(scope_type: scope_type, scope_id: scope_id, attrs: attrs)

    render json: SocialMediaSettingsService.for_company(@company, location_id: current_location_id)
  end

  private

  def scope_id_for(scope_type)
    case scope_type
    when 'Company'  then @company.id
    when 'Location' then current_location_id
    end
  end
end
