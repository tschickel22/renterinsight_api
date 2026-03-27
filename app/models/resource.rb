# frozen_string_literal: true

# Resource Model
# 
# Represents system-defined resources that can be accessed in the application.
# Resources are platform-level and seeded by migrations.
# 
# Examples: 'inventory', 'users', 'locations', 'crm', 'reports', etc.

class Resource < ApplicationRecord
  # Associations
  has_many :role_permissions, dependent: :destroy
  has_many :roles, through: :role_permissions

  # Validations
  validates :key, presence: true, uniqueness: true, length: { maximum: 100 }
  validates :name, presence: true
  validates :category, inclusion: { in: %w[core operations admin] }, allow_nil: true

  # Scopes
  scope :active, -> { where(active: true) }
  scope :by_category, ->(category) { where(category: category) }
  scope :core, -> { where(category: 'core') }
  scope :operations, -> { where(category: 'operations') }
  scope :admin, -> { where(category: 'admin') }


# Instance methods
def permission_ui_type
  # Calendar uses specialized permission UI with grouped permissions
  return 'specialized' if key == 'calendar'
  'standard_crud'
end

def permission_groups
  # Calendar has specialized permission groups
  return calendar_permission_groups if key == 'calendar'
  {}
end

private

def calendar_permission_groups
  {
    personal: {
      name: 'Personal Calendar',
      description: 'Access to personal calendar and activities',
      permissions: [
        { action: 'read', scope: 'own', label: 'View own calendar and activities' }
      ]
    },
    team: {
      name: 'Team Collaboration',
      description: 'View and manage team calendars',
      permissions: [
        { action: 'read', scope: 'assigned_locations', label: 'View team calendars at assigned locations' },
        { action: 'read', scope: 'all', label: 'View all company calendars' }
      ]
    },
    service: {
      name: 'Service Tickets',
      description: 'View service tickets in calendar',
      permissions: [
        { action: 'manage', scope: 'all', label: 'View all service tickets in calendar view' },
        { action: 'delete', scope: 'all', label: 'View unassigned service tickets' }
      ]
    },
    management: {
      name: 'Schedule Management',
      description: 'Manage and reschedule calendar items',
      permissions: [
        { action: 'update', scope: 'all', label: 'Reschedule activities and manage calendar items' }
      ]
    }
  }
end

public

  # Class methods
  def self.seed_defaults
    resources_data = [
      # Admin Resources (position 1-10)
      { key: 'company_settings', name: 'Company Settings', category: 'admin', description: 'Manage company-wide settings and configurations', position: 1 },
      { key: 'users', name: 'Users & Teams', category: 'admin', description: 'Manage users, roles, and team assignments', position: 2 },
      { key: 'locations', name: 'Locations', category: 'admin', description: 'Manage company locations and their settings', position: 3 },
      { key: 'branding', name: 'Branding & White Label', category: 'admin', description: 'Manage branding, logos, and appearance', position: 4 },
      { key: 'activity_logs', name: 'Activity Log', category: 'admin', description: 'View platform activity and user actions', position: 5 },
      
      # Operations Resources (position 100-200)
      { key: 'inventory', name: 'Inventory', category: 'operations', description: 'Manage vehicle and property inventory', position: 100 },
      { key: 'crm', name: 'CRM & Contacts', category: 'operations', description: 'Manage customer relationships and contacts', position: 101 },
      { key: 'leads', name: 'Leads', category: 'operations', description: 'Manage sales leads and conversions', position: 102 },
      { key: 'deals', name: 'Deals & Opportunities', category: 'operations', description: 'Manage sales deals and pipeline', position: 103 },
      { key: 'service', name: 'Service & Tickets', category: 'operations', description: 'Manage service tickets and maintenance', position: 104 },
      { key: 'finance', name: 'Finance & Billing', category: 'operations', description: 'Manage financial transactions and billing', position: 105 },
      { key: 'communications', name: 'Communications', category: 'operations', description: 'Send and manage emails/SMS', position: 106 },
      { key: 'listings', name: 'Property Listings', category: 'operations', description: 'Manage property listings and syndication', position: 107 },
      { key: 'products', name: 'Products', category: 'operations', description: 'Manage product catalog and pricing', position: 108 },
      { key: 'tasks', name: 'Tasks', category: 'operations', description: 'Manage tasks and to-do items across all modules', position: 109 },
      { key: 'documents', name: 'Documents', category: 'operations', description: 'Manage client documents and file uploads', position: 110 },
      { key: 'invoices', name: 'Invoices', category: 'operations', description: 'Manage invoices and billing', position: 111 },
      { key: 'loans', name: 'Loans', category: 'operations', description: 'Manage loans and financing', position: 112 },
      
      # Commissions (position 120-125)
      { key: 'commissions', name: 'Commissions', category: 'operations', description: 'Manage commission tracking and payments', position: 120 },
      { key: 'commission_plans', name: 'Commission Plans', category: 'operations', description: 'Configure commission plans and structures', position: 121 },
      { key: 'commission_components', name: 'Commission Components', category: 'operations', description: 'Manage commission calculation components', position: 122 },
      { key: 'commission_payments', name: 'Commission Payments', category: 'operations', description: 'Process commission payments', position: 123 },
      
      # Parts & Inventory Module (position 150-159 - grouped together)
      { key: 'parts', name: 'Parts', category: 'operations', description: 'Manage parts catalog, stock levels, and inventory transactions', position: 150 },
      { key: 'bins', name: 'Warehouse Bins', category: 'operations', description: 'Manage storage bin locations and organization', position: 151 },
      { key: 'suppliers', name: 'Suppliers', category: 'operations', description: 'Manage supplier information and vendor relationships', position: 152 },
      { key: 'part_categories', name: 'Part Categories', category: 'operations', description: 'Organize parts by category', position: 153 },
      { key: 'purchase_orders', name: 'Purchase Orders', category: 'operations', description: 'Manage purchase orders to suppliers', position: 154 },
      
      # Configurator (position 155)
      { key: 'configurator', name: 'Home Configurator', category: 'operations', description: 'Configure and quote manufactured homes', position: 155 },

      # Contractors (position 163)
      { key: 'contractors', name: 'Contractors', category: 'operations', description: 'Manage contractors, assignments, and portal access', position: 163 },

      # Warranty Resources (position 160-165)
      { key: 'warranty_claims', name: 'Warranty Claims', category: 'operations', description: 'Manage warranty claims and submissions to manufacturers', position: 160 },
      { key: 'manufacturer_ar', name: 'Manufacturer AR', category: 'operations', description: 'Track and manage manufacturer accounts receivable', position: 161 },
      { key: 'manufacturers', name: 'Manufacturers', category: 'operations', description: 'View and manage manufacturer information', position: 162 },
      
      # Agreements (position 115)
      { key: 'agreements', name: 'Agreements', category: 'operations', description: 'Agreement & e-sign management', position: 115 },

      # Cost Details (position 170-175)
      { key: 'inventory_cost_details', name: 'Inventory (Cost Details)', category: 'operations', description: 'View detailed cost breakdowns for inventory', position: 170 },
      { key: 'deals_cost_details', name: 'Deals (Cost Details)', category: 'operations', description: 'View detailed cost breakdowns for deals', position: 171 },
      
      # Core Resources (position 900-999)
      { key: 'calendar', name: 'Calendar', category: 'core', description: 'View and manage calendar events', position: 900 },
      { key: 'reports', name: 'Reports & Analytics', category: 'core', description: 'Access reports and analytics dashboards', position: 901 },
      { key: 'portal', name: 'Client Portal', category: 'core', description: 'Manage client portal access and content', position: 902 },
      { key: 'dashboard', name: 'Dashboard', category: 'core', description: 'View and customize dashboard', position: 903 },
      { key: 'dashboard_company_wide', name: 'Company-wide Dashboard', category: 'core', description: 'View company-wide metrics and analytics', position: 904 },
      { key: 'dashboard_finance', name: 'Finance Dashboard', category: 'core', description: 'View financial dashboards and metrics', position: 905 }
    ]
    
    resources_data.each do |resource_data|
      resource = find_or_create_by!(key: resource_data[:key]) do |r|
        r.name = resource_data[:name]
        r.category = resource_data[:category]
        r.description = resource_data[:description]
        r.active = true
        r.position = resource_data[:position]
      end
      
      # Update position for existing resources
      if resource.position != resource_data[:position]
        resource.update_column(:position, resource_data[:position])
      end
    end
  end
end
