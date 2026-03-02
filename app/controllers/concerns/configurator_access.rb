# frozen_string_literal: true

module ConfiguratorAccess
  extend ActiveSupport::Concern

  included do
    before_action :check_configurator_access
  end

  private

  def check_configurator_access
    # Platform admins always have access for testing/setup
    return if current_user&.platform_admin?

    unless @company.has_module?('sales.configurator')
      render json: {
        error: 'Configurator not available',
        message: 'Please upgrade to Professional or Enterprise tier to use the Home Configurator',
        upgrade_url: '/settings/billing'
      }, status: :forbidden
    end
  end
end
