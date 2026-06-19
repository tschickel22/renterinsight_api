# frozen_string_literal: true

# Dealer opt-in (Surface A): a company elects to pull a vetted CatalogSource's
# homes into its own inventory. Catalog runs ingest into each enabled
# subscription's company, riding the existing Vehicle inventory path.
class DealerCatalogSubscription < ApplicationRecord
  belongs_to :company
  belongs_to :catalog_source

  validates :catalog_source_id, uniqueness: { scope: :company_id }

  scope :enabled, -> { where(enabled: true) }
end
