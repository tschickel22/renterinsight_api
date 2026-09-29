# frozen_string_literal: true

# One factory model number. 2856H32392 (HUD) and 2856M32392 (modular) are two
# variants of the same plan, priced separately.
class CatalogPlanVariant < ApplicationRecord
  BUILDING_CODES = %w[HUD MOD].freeze
  STATUSES = %w[active discontinued].freeze

  belongs_to :catalog_plan
  belongs_to :manufacturer
  has_many :variant_prices, class_name: 'CatalogVariantPrice', dependent: :restrict_with_error
  has_many :vehicles, dependent: :nullify

  validates :model_number, presence: true, uniqueness: { scope: :manufacturer_id }
  validates :building_code, inclusion: { in: BUILDING_CODES }
  validates :status, inclusion: { in: STATUSES }
  validate :manufacturer_matches_plan

  before_validation :normalize_model_number

  scope :active, -> { where(status: 'active') }

  def parsed_model_number
    Catalog::ModelNumber.parse(model_number)
  end

  private

  def normalize_model_number
    return if model_number.blank?

    self.model_number_as_printed ||= model_number
    self.model_number = Catalog::ModelNumber.normalize(model_number)
    self.building_code ||= parsed_model_number.building_code
  end

  def manufacturer_matches_plan
    return if catalog_plan.nil? || manufacturer_id == catalog_plan.manufacturer_id

    errors.add(:manufacturer_id, 'must match the plan manufacturer')
  end
end
