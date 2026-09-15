# frozen_string_literal: true

module ModuleAccessRequired
  extend ActiveSupport::Concern

  class_methods do
    # Denies the action unless the company has the module.
    #
    # log_only: records who would be denied without denying anyone. For a
    # controller gated for the first time, so a tenant whose plan data does not
    # yet grant the module shows up in the logs before it ever sees a 403.
    def require_module!(module_key, log_only: false, **options)
      require_any_module!(module_key, log_only: log_only, **options)
    end

    # Allows the action when the company has any of the modules. For engines
    # several products drive: the workflow engine serves Workflow Automation
    # and Campaign Desk alike, without granting either product's own pages.
    def require_any_module!(*module_keys, log_only: false, **options)
      keys = module_keys.flatten
      before_action(**options) do
        enforce_module_access!(keys, log_only: log_only)
      end
    end
  end

  private

  def enforce_module_access!(module_keys, log_only: false)
    module_keys = Array(module_keys)
    return true if current_user&.platform_admin? || current_user&.super_admin? || current_user&.tenant?

    company = @company || ::Company.find_by(id: current_company_id)
    unless company
      return true if log_only

      render json: { error: 'Company not found' }, status: :forbidden
      return false
    end

    service = ModuleAccessService.new(company)
    return true if module_keys.any? { |key| service.has_module?(key) }

    if log_only
      Rails.logger.warn "[ModuleAccessRequired] WOULD DENY #{module_keys.join(' or ')} for company #{company.id} " \
                        "at #{controller_path}##{action_name} (log only)"
      return true
    end

    Rails.logger.warn "[ModuleAccessRequired] DENIED #{module_keys.join(' or ')} for company #{company.id}"
    render json: {
      error: 'This feature is not included in your subscription plan.',
      required_module: module_keys.first,
      required_any_of: module_keys,
      plan_name: service.subscription_status[:plan_display_name]
    }, status: :forbidden
    false
  end
end
