# frozen_string_literal: true

class CustomField < ApplicationRecord
  belongs_to :company
  
  # Validations
  validates :name, presence: true
  validates :label, presence: true
  validates :field_type, presence: true
  validates :module, presence: true
  validates :name, uniqueness: { scope: [:company_id, :module] }
  
  # Field types
  FIELD_TYPES = %w[text number email phone date select checkbox].freeze
  validates :field_type, inclusion: { in: FIELD_TYPES }
  
  # Scopes
  scope :ordered, -> { order(:display_order, :created_at) }
  scope :for_module, ->(module_name) { where(module: module_name) }
  scope :required_fields, -> { where(required: true) }
  
  # Serialize options as JSON
  serialize :options, coder: JSON
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :module, :name, :label, :field_type, :required, :default_value, :display_order],
      methods: [:options]
    ))
  end
end
