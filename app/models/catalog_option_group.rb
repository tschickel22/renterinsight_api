# frozen_string_literal: true

# Countertops, Backsplash, Flooring. Scoped to a plant and optionally a series.
class CatalogOptionGroup < ApplicationRecord
  SELECTION_TYPES = %w[single multiple quantity].freeze

  belongs_to :manufacturer
  belongs_to :factory, optional: true
  has_many :options, -> { order(:position, :id) }, class_name: 'CatalogOption', dependent: :restrict_with_error

  validates :key, :name, presence: true
  validates :key, uniqueness: { scope: %i[manufacturer_id factory_id series] }
  validates :selection_type, inclusion: { in: SELECTION_TYPES }
end
