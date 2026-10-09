# frozen_string_literal: true

# One home a dealer has chosen for a website's Featured Homes section.
#
# title and description are the site's own copy. Blank means "use what the
# inventory record says", so a dealer who never edits them still gets a
# description, and editing them never touches the inventory record.
class WebsiteFeaturedHome < ApplicationRecord
  belongs_to :website
  belongs_to :vehicle

  validates :vehicle_id, uniqueness: { scope: :website_id }
  validate :vehicle_belongs_to_website_company

  scope :ordered, -> { order(:position, :id) }

  def display_title
    title.presence || [vehicle.year, vehicle.make, vehicle.model].compact.join(' ')
  end

  def display_description
    description.presence || vehicle.description
  end

  private

  # A site can only feature its own company's homes.
  def vehicle_belongs_to_website_company
    return if website.nil? || vehicle.nil?
    return if vehicle.company_id == website.company_id

    errors.add(:vehicle, 'is not in this company inventory')
  end
end
