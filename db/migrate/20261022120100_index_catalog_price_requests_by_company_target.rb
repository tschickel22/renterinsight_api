# frozen_string_literal: true

# A dealer's cost overrides are their open and dealer_only cost requests, read
# on every price (Truebuild::DealerPrices).
class IndexCatalogPriceRequestsByCompanyTarget < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :catalog_price_requests, %i[company_id target_type target_id], algorithm: :concurrently
  end
end
