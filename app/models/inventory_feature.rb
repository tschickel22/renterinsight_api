class InventoryFeature < ApplicationRecord
  belongs_to :vehicle
  belongs_to :company

  validates :name, presence: true
  validates :name, uniqueness: { scope: :vehicle_id, message: 'already exists for this vehicle' }

  scope :by_category, ->(cat) { where(category: cat) if cat.present? }
  scope :standard,    ->      { where(is_standard: true) }
  scope :custom,      ->      { where(is_standard: false) }

  before_save :normalize_name

  private

  def normalize_name
    self.name = name&.strip
  end
end
