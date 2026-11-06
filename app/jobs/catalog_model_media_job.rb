# frozen_string_literal: true

# Pulls model photos from the manufacturer's site (Truebuild::ModelMedia,
# Truebuild::CavcoModelMedia for Cavco plants, Truebuild::FeedModelMedia for
# feeds keyed by the book's model numbers), then links dealers' listings of
# those homes to the models.
class CatalogModelMediaJob < ApplicationJob
  queue_as :low

  def perform(manufacturer_id)
    manufacturer = Manufacturer.find_by(id: manufacturer_id)
    return unless manufacturer

    Truebuild::ModelMedia.refresh!(manufacturer)
    # Cavco plants publish their own photos (cavco_plant sources).
    Truebuild::CavcoModelMedia.refresh!(manufacturer) if CatalogSource.active.where(adapter_type: 'cavco_plant').exists?
    # Feeds keyed by the book's own model numbers (Clayton SKUs).
    plants = manufacturer.factories.pluck(:id)
    Truebuild::FeedModelMedia.sources.each do |source|
      Truebuild::FeedModelMedia.refresh!(source) if Array(source.config['factory_ids']).map(&:to_i).intersect?(plants)
    end
    # Dealers' listings of those homes link to the models just matched, so
    # "Design this home" and TrueView reach them.
    Truebuild::HomeMatcher.new.link_by_feed_key_all(Vehicle.where(is_deleted: [false, nil]))
  end
end
