# frozen_string_literal: true

# GET/PUT/DELETE per-company tooltip overrides for both system fields (real
# AR columns like leads.email) and custom fields. Custom-field tooltips can
# also be edited directly on CustomField#description via the existing
# CustomFieldsController; this controller is the write path for system fields
# and the read path for both (resolved values merge automatically).
class Api::V1::FieldTooltipsController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/company/field-tooltips
  # Returns the full overrides map plus custom-field descriptions grouped by
  # module so the frontend can render "current tooltip" in the editor without
  # a second round-trip.
  def index
    return unless authorize_action!('company_settings', 'read')

    render json: {
      overrides: @company.field_tooltip_overrides,
      custom_field_descriptions: custom_field_descriptions
    }
  end

  # PUT /api/v1/company/field-tooltips
  # Body: { module: "leads", field_key: "email", text: "Primary contact..." }
  # Blank text clears the override.
  def update
    return unless authorize_action!('company_settings', 'update')

    mod = params[:module].to_s
    key = params[:field_key].to_s
    if mod.blank? || key.blank?
      return render json: { error: 'module and field_key are required' }, status: :bad_request
    end

    overrides = @company.save_field_tooltip(mod, key, params[:text])
    render json: { overrides: overrides }
  end

  # DELETE /api/v1/company/field-tooltips/:module/:field_key
  def destroy
    return unless authorize_action!('company_settings', 'update')

    overrides = @company.clear_field_tooltip!(params[:module], params[:field_key])
    render json: { overrides: overrides }
  end

  # POST /api/v1/company/field-tooltips/reset
  def reset
    return unless authorize_action!('company_settings', 'update')

    @company.reset_field_tooltips!
    render json: { overrides: {} }
  end

  private

  # Serialize custom-field descriptions grouped by module so the editor can
  # show them as read-only "default" values alongside any override.
  def custom_field_descriptions
    @company.custom_fields
      .where(is_active: true)
      .pluck(:module, :field_key, :description)
      .each_with_object({}) do |(mod, key, desc), acc|
        next if desc.blank?
        acc[mod.to_s] ||= {}
        acc[mod.to_s][key.to_s] = desc
      end
  end
end
