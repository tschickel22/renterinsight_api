# frozen_string_literal: true

# Registry of all platform modules that can be enabled/disabled per subscription plan
# This serves as the single source of truth for module definitions
class PlatformModule
  # Module definitions organized by category
  MODULES = {
    # CRM & Sales
    'crm.prospecting' => { name: 'Lead Prospecting', category: 'CRM & Sales', icon: 'Users', description: 'Lead capture and nurturing' },
    'crm.accounts' => { name: 'Account Management', category: 'CRM & Sales', icon: 'Building', description: 'Customer account management' },
    'crm.contacts' => { name: 'Contact Management', category: 'CRM & Sales', icon: 'UserCircle', description: 'Contact database and communication' },
    'crm.deals' => { name: 'Sales Pipeline', category: 'CRM & Sales', icon: 'TrendingUp', description: 'Deal tracking and sales process' },
    'crm.quotes' => { name: 'Quote Builder', category: 'CRM & Sales', icon: 'FileText', description: 'Professional quote generation' },
    'sales.configurator' => { name: 'Home Configurator', category: 'CRM & Sales', icon: 'Home', description: 'Configure and quote manufactured homes' },
    
    # Inventory & Operations
    'inventory.vehicles' => { name: 'Inventory Management', category: 'Inventory & Operations', icon: 'Package', description: 'Vehicle and unit inventory tracking' },
    'inventory.parts' => { name: 'Parts Management', category: 'Inventory & Operations', icon: 'Box', description: 'Parts inventory and stock management' },
    'inventory.land' => { name: 'Land Management', category: 'Inventory & Operations', icon: 'Map', description: 'Land and lot inventory management' },
    'inventory.lot_map' => { name: 'Lot Map', category: 'Inventory & Operations', icon: 'MapPin', description: 'Visual lot mapping and assignment' },
    'inventory.pdi' => { name: 'PDI Checklist', category: 'Inventory & Operations', icon: 'ClipboardCheck', description: 'Pre-delivery inspection management' },
    'inventory.delivery' => { name: 'Delivery Tracker', category: 'Inventory & Operations', icon: 'Truck', description: 'Delivery scheduling and tracking' },
    'inventory.champion_ims' => { name: 'Champion IMS Feed', category: 'Inventory & Operations', icon: 'Rss', description: 'Sync manufactured home catalog from Champion Homes IMS feeds' },
    
    # Marketing
    'marketing.listings' => { name: 'Property Listings', category: 'Marketing', icon: 'Globe', description: 'Public property listing management' },
    'marketing.brochures' => { name: 'Brochure Generator', category: 'Marketing', icon: 'FileImage', description: 'Marketing brochure creation' },
    'marketing.website' => { name: 'Website Builder', category: 'Marketing', icon: 'Layout', description: 'Custom website creation and management' },
    'marketing.syndication' => { name: 'Listing Syndication', category: 'Marketing', icon: 'Share2', description: 'Syndicate listings to partner sites' },
    'marketing.social_media' => { name: 'Social Media & Ads', category: 'Marketing', icon: 'Share2', description: 'Social posts, scheduler, attribution, and Facebook ad builder' },
    
    # Finance & Agreements
    'finance.loans' => { name: 'Finance Management', category: 'Finance & Agreements', icon: 'DollarSign', description: 'Loan and payment management' },
    'finance.agreements' => { name: 'Agreement Vault', category: 'Finance & Agreements', icon: 'FileSignature', description: 'Digital contract management' },
    'finance.invoices' => { name: 'Invoice & Payments', category: 'Finance & Agreements', icon: 'Receipt', description: 'Billing and payment processing' },
    'finance.documents' => { name: 'Document Management', category: 'Finance & Agreements', icon: 'FolderOpen', description: 'Client document storage and management' },
    'finance.applications' => { name: 'Finance Applications', category: 'Finance & Agreements', icon: 'FileCheck', description: 'Customer finance application processing' },
    
    # Service & Support
    'service.operations' => { name: 'Service Operations', category: 'Service & Support', icon: 'Wrench', description: 'Service ticket and work order management' },
    'service.portal' => { name: 'Client Portal', category: 'Service & Support', icon: 'Users', description: 'Customer self-service portal' },
    'service.warranty' => { name: 'Warranty Management', category: 'Service & Support', icon: 'Shield', description: 'Warranty claims and tracking' },
    
    # Management
    'management.reports' => { name: 'Reporting Suite', category: 'Management', icon: 'BarChart', description: 'Advanced analytics and reporting' },
    'management.commissions' => { name: 'Commission Engine', category: 'Management', icon: 'Percent', description: 'Sales commission tracking and calculation' },
    'management.tags' => { name: 'Tagging Engine', category: 'Management', icon: 'Tag', description: 'Advanced tagging and categorization' },
    'management.tasks' => { name: 'Task Center', category: 'Management', icon: 'CheckSquare', description: 'Task management and workflow' },
    'management.calendar' => { name: 'Calendar Scheduling', category: 'Management', icon: 'Calendar', description: 'Appointment and event scheduling' },
    'management.contractors' => { name: 'Contractor Management', category: 'Management', icon: 'Briefcase', description: 'External contractor coordination' },
    'management.projects' => { name: 'Project Management', category: 'Management', icon: 'FolderKanban', description: 'Project tracking with phases, tasks, and client visibility' },
    'management.workflows' => { name: 'Workflow Automation', category: 'Management', icon: 'GitBranch', description: 'Business process automation' },
    'management.territories' => { name: 'Territory Management', category: 'Management', icon: 'MapPin', description: 'Sales territory assignment and tracking' },
    'management_ai_reports' => { name: 'AI Report Queries', category: 'Management', icon: 'Sparkles', description: 'Natural language AI queries for reports' },
    
    # Administration
    'admin.settings' => { name: 'Company Settings', category: 'Administration', icon: 'Settings', description: 'Company configuration and branding' },
    'admin.users' => { name: 'User Management', category: 'Administration', icon: 'Users', description: 'User accounts and access control' },
    'admin.locations' => { name: 'Location Management', category: 'Administration', icon: 'Building2', description: 'Multi-location management' },
    'admin.roles' => { name: 'Role Management', category: 'Administration', icon: 'Shield', description: 'Custom roles and permissions' },
    'admin.api_keys' => { name: 'API Keys', category: 'Administration', icon: 'Key', description: 'External API key management for integrations' },
    'admin.webhooks' => { name: 'Webhooks', category: 'Administration', icon: 'Webhook', description: 'Webhook endpoint management for event notifications' },
    'admin.platform' => { name: 'Platform Admin', category: 'Administration', icon: 'Crown', description: 'Platform-level administration (Enterprise only)' }
  }.freeze
  
  # Category definitions with icons
  CATEGORIES = {
    'CRM & Sales' => { icon: 'Users', description: 'Customer relationship management and sales pipeline', position: 1 },
    'Inventory & Operations' => { icon: 'Package', description: 'Inventory management and operational workflows', position: 2 },
    'Marketing' => { icon: 'Globe', description: 'Marketing tools and website management', position: 3 },
    'Finance & Agreements' => { icon: 'DollarSign', description: 'Financial management and legal agreements', position: 4 },
    'Service & Support' => { icon: 'Wrench', description: 'Customer service and support tools', position: 5 },
    'Management' => { icon: 'BarChart3', description: 'Business management and analytics tools', position: 6 },
    'Administration' => { icon: 'Settings', description: 'System administration and configuration', position: 7 }
  }.freeze
  
  # Predefined module sets for plan templates
  PLAN_TEMPLATES = {
    starter: %w[
      crm.prospecting crm.accounts crm.contacts crm.quotes
      inventory.vehicles
      admin.settings admin.users
    ],
    professional: %w[
      crm.prospecting crm.accounts crm.contacts crm.deals crm.quotes sales.configurator
      inventory.vehicles inventory.parts inventory.land inventory.lot_map inventory.pdi inventory.delivery
      marketing.listings marketing.brochures marketing.social_media
      finance.loans finance.agreements finance.invoices finance.documents finance.applications
      service.operations service.portal
      management.reports management.tags management.tasks management.calendar management.projects
      admin.settings admin.users admin.locations
    ],
    enterprise: %w[
      crm.prospecting crm.accounts crm.contacts crm.deals crm.quotes sales.configurator
      inventory.vehicles inventory.parts inventory.land inventory.lot_map inventory.pdi inventory.delivery inventory.champion_ims
      marketing.listings marketing.brochures marketing.website marketing.syndication marketing.social_media
      finance.loans finance.agreements finance.invoices finance.documents finance.applications
      service.operations service.portal service.warranty
      management.reports management.commissions management.tags management.tasks 
      management.calendar management.contractors management.projects management.workflows management.territories
      admin.settings admin.users admin.locations admin.roles admin.api_keys admin.webhooks
    ]
  }.freeze
  
  class << self
    # Get all module keys
    def all_keys
      MODULES.keys
    end
    
    # Get all modules as array with keys
    def all
      MODULES.map { |key, info| info.merge(key: key) }
    end
    
    # Find a specific module by key
    def find(key)
      info = MODULES[key]
      info&.merge(key: key)
    end
    
    # Check if a module key is valid
    def valid_key?(key)
      MODULES.key?(key)
    end
    
    # Get modules by category
    def by_category(category)
      MODULES.select { |_, info| info[:category] == category }
              .map { |key, info| info.merge(key: key) }
    end
    
    # Get all categories with their modules
    def categories_with_modules
      CATEGORIES.map do |name, cat_info|
        {
          name: name,
          icon: cat_info[:icon],
          description: cat_info[:description],
          position: cat_info[:position],
          modules: by_category(name)
        }
      end.sort_by { |c| c[:position] }
    end
    
    # Default module configs per plan template
    # Only modules that need config are listed here
    PLAN_CONFIG_DEFAULTS = {
      starter: {},
      professional: {
        'marketing.website' => { 'website_access_level' => 2 }  # Content Editor
      },
      enterprise: {
        'marketing.website' => { 'website_access_level' => 3 }  # Full Editor
      }
    }.freeze

    # Get module keys for a plan template
    def template_modules(template_name)
      PLAN_TEMPLATES[template_name.to_sym] || []
    end

    # Get default configs for a plan template
    def default_configs_for_template(template_name)
      PLAN_CONFIG_DEFAULTS[template_name.to_sym] || {}
    end
    
    # Get modules as hash for plan creation { key => true/false }
    def modules_hash_for_template(template_name)
      enabled_keys = template_modules(template_name)
      MODULES.keys.each_with_object({}) do |key, hash|
        hash[key] = enabled_keys.include?(key)
      end
    end
    
    # Serialize for frontend
    def as_json_with_categories
      {
        categories: categories_with_modules,
        all_modules: all
      }
    end
  end
end
