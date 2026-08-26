# frozen_string_literal: true

# Per-tenant export controls, set from Platform Admin. Deliberately outside
# RBAC: whether a tenant may pull machine-readable exports is a commercial
# decision we make about them, not a permission they administer themselves.
class Api::Platform::TenantExportSettingsController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_tenant

  # GET /api/platform/tenants/:tenant_id/export_settings
  def show
    render json: payload
  end

  # PATCH /api/platform/tenants/:tenant_id/export_settings
  def update
    settings = ImportExport::ExportPolicy.settings_for(@tenant)

    if params.key?(:allow_json)
      settings['allow_json'] = ActiveModel::Type::Boolean.new.cast(params[:allow_json]) || false
    end

    %w[daily_export_limit max_export_rows alert_row_threshold].each do |key|
      next unless params.key?(key)

      value = params[key].to_i
      if value.negative?
        return render json: { error: "#{key} must be 0 or greater (0 = unlimited)" },
                      status: :unprocessable_entity
      end

      settings[key] = value
    end

    Setting.set(
      ImportExport::ExportPolicy::SETTING_SCOPE,
      @tenant.id,
      ImportExport::ExportPolicy::SETTING_KEY,
      settings
    )

    render json: payload.merge(message: 'Export settings updated')
  end

  private

  def set_tenant
    @tenant = Company.find(params[:tenant_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Tenant not found' }, status: :not_found
  end

  def payload
    settings = ImportExport::ExportPolicy.settings_for(@tenant)
    {
      company_id:      @tenant.id,
      company_name:    @tenant.name,
      settings:        settings,
      defaults:        ImportExport::ExportPolicy::DEFAULTS,
      allowed_formats: ImportExport::ExportPolicy.allowed_formats(@tenant)
    }
  end
end
