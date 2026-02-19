# frozen_string_literal: true

class PageLayout < ApplicationRecord
  belongs_to :company
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true

  validates :module_name, presence: true
  validates :layout_type, presence: true
  validates :layout_type, uniqueness: { scope: [:company_id, :module_name] }

  scope :for_module, ->(mod) { where(module_name: mod) }

  # Fields that can NEVER be hidden per module
  PROTECTED_FIELDS = {
    'leads' => %w[first_name last_name email phone].freeze,
    'accounts' => %w[name].freeze,
    'contacts' => %w[first_name last_name email].freeze
  }.freeze

  LAYOUT_TYPES = %w[detail edit list].freeze

  validates :layout_type, inclusion: { in: LAYOUT_TYPES }

  # Returns the default layout JSON for a given module
  def self.default_layout_for(module_name)
    case module_name
    when 'leads'
      default_leads_layout
    when 'accounts'
      default_accounts_layout
    when 'contacts'
      default_contacts_layout
    else
      { sections: [] }
    end
  end

  private_class_method def self.default_accounts_layout
    {
      sections: [
        {
          id: 'account_info',
          title: 'Account Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'account_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'email', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'phone', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'website', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'industry', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'details',
          title: 'Account Details',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'status', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rating', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'ownership', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'source_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'owner_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'annual_revenue', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'employee_count', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'billing_address',
          title: 'Billing Address',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'billing_street', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'billing_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'billing_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'billing_postal_code', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'billing_country', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'shipping_address',
          title: 'Shipping Address',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'shipping_street', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'shipping_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'shipping_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'shipping_postal_code', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'shipping_country', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'notes_section',
          title: 'Notes & Description',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'description', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'notes', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'custom_fields',
          title: 'Custom Fields',
          columns: 2,
          collapsed: false,
          fields: []
        }
      ]
    }
  end

  private_class_method def self.default_contacts_layout
    {
      sections: [
        {
          id: 'contact_info',
          title: 'Contact Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'first_name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'last_name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'email', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'phone', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'details',
          title: 'Contact Details',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'title', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'department', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'company_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'account_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'owner_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'is_primary', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'address',
          title: 'Address',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'street', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'zip', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'country', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'preferences',
          title: 'Preferences',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'opt_out_email', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'opt_out_sms', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'notes_section',
          title: 'Notes',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'notes', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'custom_fields',
          title: 'Custom Fields',
          columns: 2,
          collapsed: false,
          fields: []
        }
      ]
    }
  end

  private_class_method def self.default_leads_layout
    {
      sections: [
        {
          id: 'contact_info',
          title: 'Contact Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'first_name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'last_name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'email', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'phone', type: 'standard', visible: true, required: true, width: 1 }
          ]
        },
        {
          id: 'details',
          title: 'Lead Details',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'status', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'owner_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'source_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'budget_range', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'purchase_timeframe', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rv_experience', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'notes_section',
          title: 'Notes & Requirements',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'interests_requirements', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'notes', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'custom_fields',
          title: 'Custom Fields',
          columns: 2,
          collapsed: false,
          fields: []
        }
      ]
    }
  end
end
