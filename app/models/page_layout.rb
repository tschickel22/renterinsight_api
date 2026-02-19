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
    'leads' => %w[first_name last_name email phone].freeze
  }.freeze

  LAYOUT_TYPES = %w[detail edit list].freeze

  validates :layout_type, inclusion: { in: LAYOUT_TYPES }

  # Returns the default layout JSON for a given module
  def self.default_layout_for(module_name)
    case module_name
    when 'leads'
      default_leads_layout
    else
      { sections: [] }
    end
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
            { key: 'rv_experience', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'preferred_contact_method', type: 'standard', visible: true, required: false, width: 1 }
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
