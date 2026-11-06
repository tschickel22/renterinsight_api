# frozen_string_literal: true

# Pulls model photos from the manufacturer's site (Truebuild::ModelMedia,
# and Truebuild::CavcoModelMedia for Cavco plants).
class CatalogModelMediaJob < ApplicationJob
  queue_as :low

  def perform(manufacturer_id)
    manufacturer = Manufacturer.find_by(id: manufacturer_id)
    return unless manufacturer

    Truebuild::ModelMedia.refresh!(manufacturer)
    # Cavco plants publish their own photos (cavco_plant sources).
    Truebuild::CavcoModelMedia.refresh!(manufacturer) if CatalogSource.active.where(adapter_type: 'cavco_plant').exists?
  end
end
