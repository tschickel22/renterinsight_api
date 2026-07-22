# frozen_string_literal: true

# Conversion-tracking settings for public intake forms.
#
# Single company-scoped screen: the company default plus a per-location
# override for each active location, all edited/saved together by a company
# user. Mirrors Api::V1::LabelsController (set_company_scope + authorize_action!).
class Api::V1::TrackingSettingsController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/company/tracking-settings
  def show
    return unless authorize_action!('company_settings', 'read')

    render json: payload
  end

  # PUT /api/v1/company/tracking-settings
  # Body: { company: {metaPixelId, ...}, locations: [{ id, tracking: {...} }] }
  def update
    return unless authorize_action!('company_settings', 'update')

    @company.save_tracking_defaults(params[:company]) unless params[:company].nil?

    Array(params[:locations]).each do |loc_param|
      location = @company.locations.find_by(id: loc_param[:id])
      next unless location

      location.update!(tracking_settings: Company.sanitize_tracking(loc_param[:tracking]))
    end

    render json: payload
  end

  private

  def payload
    {
      keys: Company::TRACKING_KEYS,
      company: @company.tracking_defaults,
      locations: @company.locations.active.order(:name).map do |loc|
        {
          id: loc.id,
          name: loc.name,
          city: loc.city,
          state: loc.state,
          tracking: Company.sanitize_tracking(loc.tracking_settings)
        }
      end
    }
  end
end
