# frozen_string_literal: true

class ImportTemplate < ApplicationRecord
  belongs_to :company, optional: true

  validates :name, presence: true
  validates :module_type, presence: true

  scope :for_module, ->(mod) { where(module_type: mod) }
  scope :platform_defaults, -> { where(is_platform_default: true) }
end
