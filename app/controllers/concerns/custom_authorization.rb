module CustomAuthorization
  extend ActiveSupport::Concern
  
  # Financial permissions constants
  FINANCIAL_PERMISSIONS = {
    # Inventory field-level
    'inventory.view_cost' => {
      name: 'View Vehicle Cost',
      description: 'Can see cost/invoice on inventory',
      category: 'financial',
      default_roles: ['company_administrator', 'finance_manager', 'general_manager']
    },
    'inventory.edit_cost' => {
      name: 'Edit Vehicle Cost',
      description: 'Can modify cost/invoice on inventory',
      category: 'financial',
      default_roles: ['company_administrator', 'finance_manager']
    },
    
    # Deal financials tab
    'deals.view_financials' => {
      name: 'View Deal Financials',
      description: 'Can see financials tab with cost, margins, gross',
      category: 'financial',
      default_roles: ['company_administrator', 'finance_manager', 'general_manager']
    },
    'deals.edit_financials' => {
      name: 'Edit Deal Financials',
      description: 'Can modify cost, pack, F&I margins',
      category: 'financial',
      default_roles: ['company_administrator', 'finance_manager']
    },
    
    # Commission visibility
    'commissions.view_all' => {
      name: 'View All Commissions',
      description: 'Can see all user commissions (not just own)',
      category: 'financial',
      default_roles: ['company_administrator', 'finance_manager', 'general_manager']
    },
    'commissions.view_components' => {
      name: 'View Commission Components',
      description: 'Can see commission structure/rates',
      category: 'financial',
      default_roles: ['company_administrator', 'finance_manager']
    }
  }.freeze
  
  # Check if user has custom permission
  def has_custom_permission?(permission_key)
    return true if current_user.nil? && permission_key.blank?
    return false if current_user.nil?
    return true if current_user.role == 'platform_admin'
    return true if current_user.role == 'company_administrator'
    
    # Check user's custom permissions array
    current_user.custom_permissions&.include?(permission_key.to_s) || false
  end
  
  # Authorize with return pattern (like authorize_action!)
  def authorize_custom_permission!(permission_key)
    unless has_custom_permission?(permission_key)
      render json: { 
        error: 'Insufficient permissions', 
        required_permission: permission_key 
      }, status: :forbidden
      return false
    end
    true
  end
  
  # Get all available custom permissions
  def self.available_permissions
    FINANCIAL_PERMISSIONS
  end
  
  # Get permissions for a specific role
  def self.default_permissions_for_role(role_key)
    FINANCIAL_PERMISSIONS.select { |_key, config| 
      config[:default_roles].include?(role_key.to_s)
    }.keys
  end
end
