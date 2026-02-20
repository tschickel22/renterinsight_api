# frozen_string_literal: true

class FieldOptionOverride < ApplicationRecord
  belongs_to :company

  validates :module_name, presence: true
  validates :field_key, presence: true
  validates :options, presence: true
  validates :field_key, uniqueness: { scope: [:company_id, :module_name] }

  scope :for_module, ->(mod) { where(module_name: mod) }
  scope :for_field, ->(key) { where(field_key: key) }
end
