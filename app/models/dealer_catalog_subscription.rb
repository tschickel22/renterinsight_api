# frozen_string_literal: true

# Dealer opt-in (Surface A): a company elects to pull a vetted CatalogSource's
# homes into its own inventory. Catalog runs ingest into each enabled
# subscription's company, riding the existing Vehicle inventory path.
#
# location_ids controls WHERE the homes appear:
#   []        -> all locations (company-wide; ingested with location_id = nil)
#   [3, 5]    -> only those locations (one Vehicle copy per location)
class DealerCatalogSubscription < ApplicationRecord
  belongs_to :company
  belongs_to :catalog_source

  validates :catalog_source_id, uniqueness: { scope: :company_id }

  scope :enabled, -> { where(enabled: true) }

  # Locations to ingest into. Empty selection => [nil] (one company-wide copy);
  # otherwise one copy per chosen location id.
  def ingest_location_ids
    ids = Array(location_ids).map(&:to_i).uniq
    ids.empty? ? [nil] : ids
  end
end
