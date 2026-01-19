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

  # Class methods
  def self.seed_defaults
    [
      { key: 'company_settings', name: 'Company Settings', category: 'admin', description: 'Manage company-wide settings and configurations' },
      { key: 'users', name: 'Users & Teams', category: 'admin', description: 'Manage users, roles, and team assignments' },
      { key: 'locations', name: 'Locations', category: 'admin', description: 'Manage company locations and their settings' },
      { key: 'inventory', name: 'Inventory', category: 'operations', description: 'Manage vehicle and property inventory' },
      { key: 'crm', name: 'CRM & Contacts', category: 'operations', description: 'Manage customer relationships and contacts' },
      { key: 'leads', name: 'Leads', category: 'operations', description: 'Manage sales leads and conversions' },
      { key: 'deals', name: 'Deals & Opportunities', category: 'operations', description: 'Manage sales deals and pipeline' },
      { key: 'service', name: 'Service & Tickets', category: 'operations', description: 'Manage service tickets and maintenance' },
      { key: 'finance', name: 'Finance & Billing', category: 'operations', description: 'Manage financial transactions and billing' },
      { key: 'reports', name: 'Reports & Analytics', category: 'core', description: 'Access reports and analytics dashboards' },
      { key: 'portal', name: 'Client Portal', category: 'core', description: 'Manage client portal access and content' },
      { key: 'branding', name: 'Branding & White Label', category: 'admin', description: 'Manage branding, logos, and appearance' },
      { key: 'communications', name: 'Communications', category: 'operations', description: 'Send and manage emails/SMS' },
      { key: 'listings', name: 'Property Listings', category: 'operations', description: 'Manage property listings and syndication' },
      { key: 'products', name: 'Products', category: 'operations', description: 'Manage product catalog and pricing' },
      { key: 'tasks', name: 'Tasks', category: 'operations', description: 'Manage tasks and to-do items across all modules' },
      { key: 'documents', name: 'Documents', category: 'operations', description: 'Manage client documents and file uploads' },
      # Parts & Inventory Module
      { key: 'parts', name: 'Parts & Inventory', category: 'operations', description: 'Manage parts catalog, stock levels, and inventory transactions' },
      # Warranty Resources
      { key: 'warranty_claims', name: 'Warranty Claims', category: 'operations', description: 'Manage warranty claims and submissions to manufacturers' },
      { key: 'manufacturer_ar', name: 'Manufacturer AR', category: 'operations', description: 'Track and manage manufacturer accounts receivable' },
      { key: 'manufacturers', name: 'Manufacturers', category: 'operations', description: 'View and manage manufacturer information' }
    ].each do |resource_data|
      find_or_create_by!(key: resource_data[:key]) do |resource|
        resource.name = resource_data[:name]
        resource.category = resource_data[:category]
        resource.description = resource_data[:description]
        resource.active = true
      end
    end
  end
end
