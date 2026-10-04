# frozen_string_literal: true

# Pulls model photos from the manufacturer's site (Truebuild::ModelMedia).
class CatalogModelMediaJob < ApplicationJob
  queue_as :low

  def perform(manufacturer_id)
    manufacturer = Manufacturer.find_by(id: manufacturer_id)
    Truebuild::ModelMedia.refresh!(manufacturer) if manufacturer
  end
end
