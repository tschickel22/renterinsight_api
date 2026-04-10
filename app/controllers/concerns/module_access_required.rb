# frozen_string_literal: true

module ModuleAccessRequired
  extend ActiveSupport::Concern

  class_methods do
    def require_module!(module_key, **options)
      before_action(**options) do
        enforce_module_access!(module_key)
      end
    end
  end

  private

  def enforce_module_access!(module_key)
    return true if current_user&.platform_admin? || current_user&.super_admin?

    company = @company || ::Company.find_by(id: current_company_id)
    unless company
      render json: { error: 'Company not found' }, status: :forbidden
      return false
    end

    service = ModuleAccessService.new(company)
    unless service.has_module?(module_key)
      Rails.logger.warn "[ModuleAccessRequired] DENIED #{module_key} for company #{company.id}"
      render json: {
        error: 'This feature is not included in your subscription plan.',
        required_module: module_key,
        plan_name: service.subscription_status[:plan_display_name]
      }, status: :forbidden
      return false
    end

    true
  end
end
