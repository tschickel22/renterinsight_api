# frozen_string_literal: true

# A plan family ("Belvidere"): one floor plan sold in several sizes and codes.
# Platform data, shared by every dealer subscribed to the manufacturer.
class CatalogPlan < ApplicationRecord
  STATUSES = %w[active discontinued].freeze

  belongs_to :manufacturer
  belongs_to :factory, optional: true
  has_many :variants, class_name: 'CatalogPlanVariant', dependent: :restrict_with_error

  validates :series, :name, :slug, presence: true
  validates :slug, uniqueness: { scope: %i[manufacturer_id series] }
  validates :status, inclusion: { in: STATUSES }

  before_validation { self.slug = name.to_s.parameterize if slug.blank? && name.present? }

  scope :active, -> { where(status: 'active') }
end
