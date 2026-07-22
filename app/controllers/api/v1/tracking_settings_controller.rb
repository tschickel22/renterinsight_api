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
  #
  # Whole update runs in one transaction so a partial save can't slip through
  # (previously: company + earlier locations saved, later location raised
  # RecordInvalid, response was 500 with half the change committed).
  #
  # We `update_column` the JSONB blob directly instead of the model's normal
  # `update!` path because the data was already whitelisted + sanitized by
  # Company.sanitize_tracking — there's nothing to validate on a passthrough
  # blob, and running full-record validations resurfaces every legacy
  # `country: "USA"` / long-zip / missing-timezone landmine on unrelated
  # Location columns. update_column bypasses AR validations + callbacks +
  # updated_at, which is the right shape for saving a settings blob.
  def update
    return unless authorize_action!('company_settings', 'update')

    ActiveRecord::Base.transaction do
      if params[:company]
        sanitized = Company.sanitize_tracking(params[:company])
        @company.update_column(:tracking_settings, sanitized)
      end

      Array(params[:locations]).each do |loc_param|
        location = @company.locations.find_by(id: loc_param[:id])
        next unless location

        sanitized = Company.sanitize_tracking(loc_param[:tracking])
        location.update_column(:tracking_settings, sanitized)
      end
    end

    render json: payload
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence },
           status: :unprocessable_entity
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
