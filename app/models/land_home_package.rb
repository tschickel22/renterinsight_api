# frozen_string_literal: true

# A land parcel and a home offered together at one price.
#
# The pairing is its own record: one lot can be offered with several homes,
# and one home on several lots, each with its own price and description.
# The parcel and the home keep their own prices; the package price is what
# the buyer is quoted for the two together.
class LandHomePackage < ApplicationRecord
  belongs_to :company
  belongs_to :land_parcel
  belongs_to :vehicle

  validates :vehicle_id, uniqueness: { scope: :land_parcel_id, message: 'is already paired with this lot' }
  validates :price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :same_company

  scope :ordered, -> { order(:position, :id) }

  # The lot's price plus the home's, the starting point a dealer adjusts.
  def self.suggested_price(land_parcel, vehicle)
    home = vehicle.sale_price.presence || vehicle.msrp.presence
    return nil if land_parcel.price.nil? && home.nil?

    land_parcel.price.to_d + home.to_d
  end

  def display_name
    name.presence || "#{vehicle_name} on #{land_parcel.display_name}"
  end

  def vehicle_name
    [vehicle.year, vehicle.make, vehicle.model].compact.join(' ')
  end

  # Whether a visitor can be offered it: both halves still for sale.
  def offerable?(home_statuses)
    show_on_website &&
      !land_parcel.is_deleted && land_parcel.status == 'available' &&
      !vehicle.is_deleted && home_statuses.include?(vehicle.status)
  end

  private

  def same_company
    return if land_parcel.nil? || vehicle.nil? || company_id.nil?

    errors.add(:land_parcel, 'is not in this company') if land_parcel.company_id != company_id
    errors.add(:vehicle, 'is not in this company') if vehicle.company_id != company_id
  end
end
