# Returns the current user's company module access information
# Used by frontend to determine which features to show/hide
class Api::V1::ModuleAccessController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/module-access
  # Returns the current company's module access and subscription info
  def show
    service = ModuleAccessService.new(@company)
    
    render json: {
      subscription: service.subscription_status,
      modules: service.modules_with_status,
      modules_by_category: service.modules_by_category,
      enabled_modules: service.enabled_modules
    }
  end

  # GET /api/v1/module-access/check/:module_key
  # Quick check if a specific module is enabled
  def check
    module_key = params[:module_key]
    
    unless PlatformModule.valid_key?(module_key)
      return render json: { error: "Invalid module key" }, status: :bad_request
    end

    service = ModuleAccessService.new(@company)
    enabled = service.has_module?(module_key)
    module_info = PlatformModule.find(module_key)

    render json: {
      module_key: module_key,
      enabled: enabled,
      module_name: module_info&.dig(:name),
      module_category: module_info&.dig(:category)
    }
  end

  # GET /api/v1/module-access/navigation
  # Returns navigation items filtered by enabled modules
  def navigation
    service = ModuleAccessService.new(@company)
    enabled = service.enabled_modules

    # Define navigation structure with module requirements
    navigation_items = build_navigation_structure(enabled)

    render json: {
      navigation: navigation_items,
      enabled_modules: enabled
    }
  end

  private

  def build_navigation_structure(enabled_modules)
    # Map navigation items to required modules
    nav_config = {
      dashboard: { module: nil, always_visible: true },
      
      # CRM & Sales
      leads: { module: 'crm.prospecting' },
      accounts: { module: 'crm.accounts' },
      contacts: { module: 'crm.contacts' },
      deals: { module: 'crm.deals' },
      quotes: { module: 'crm.quotes' },
      
      # Inventory
      inventory: { module: 'inventory.vehicles' },
      land_management: { module: 'inventory.land' },
      lot_map: { module: 'inventory.lot_map' },
      pdi_checklist: { module: 'inventory.pdi' },
      delivery_tracker: { module: 'inventory.delivery' },
      
      # Marketing
      listings: { module: 'marketing.listings' },
      brochures: { module: 'marketing.brochures' },
      website_builder: { module: 'marketing.website' },
      
      # Finance
      finance: { module: 'finance.loans' },
      agreements: { module: 'finance.agreements' },
      invoices: { module: 'finance.invoices' },
      finance_applications: { module: 'finance.applications' },
      
      # Service
      service: { module: 'service.operations' },
      client_portal: { module: 'service.portal' },
      
      # Management
      reports: { module: 'management.reports' },
      commissions: { module: 'management.commissions' },
      tags: { module: 'management.tags' },
      tasks: { module: 'management.tasks' },
      calendar: { module: 'management.calendar' },
      contractors: { module: 'management.contractors' },
      workflows: { module: 'management.workflows' },
      
      # Administration
      settings: { module: 'admin.settings' },
      platform_admin: { module: 'admin.platform' }
    }

    # Filter and return enabled navigation items
    nav_config.transform_values do |config|
      {
        enabled: config[:always_visible] || 
                 config[:module].nil? || 
                 enabled_modules.include?(config[:module]),
        module: config[:module]
      }
    end
  end
end
