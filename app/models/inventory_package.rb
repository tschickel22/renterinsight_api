# frozen_string_literal: true

class InventoryPackage < ApplicationRecord
  belongs_to :vehicle
  belongs_to :package_template, optional: true

  validates :name, presence: true
  validates :price, numericality: true, allow_nil: true  # Allows negative for credits/discounts

  scope :ordered, -> { order(:position, :name) }
  scope :included_in_total, -> { where(include_in_total: true) }
end
