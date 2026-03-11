# frozen_string_literal: true

class InventoryPackage < ApplicationRecord
  belongs_to :vehicle
  belongs_to :package_template, optional: true

  validates :name, presence: true
  validates :price, numericality: true, allow_nil: true  # Allows negative for credits/discounts

  scope :ordered, -> { order(:position, :name) }
  scope :included_in_total, -> { where(include_in_total: true) }

  # Recompute vehicle discount when packages change
  after_save :recompute_vehicle_discount
  after_destroy :recompute_vehicle_discount

  private

  def recompute_vehicle_discount
    return unless vehicle&.respond_to?(:special_discount_enabled)
    return unless vehicle.special_discount_enabled

    # Force recompute and save (skips validation to avoid infinite loop)
    vehicle.send(:compute_discounted_price)
    vehicle.save(validate: false) if vehicle.changed?
  end
end
