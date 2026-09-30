# frozen_string_literal: true

# Freight is flat plus a rate per mile. Neither plants nor dealer locations
# carry coordinates, so the dealer states how far they are from the plant.
class AddFreightMilesToDealerCatalogTerms < ActiveRecord::Migration[8.0]
  def change
    add_column :dealer_catalog_terms, :freight_miles, :integer
  end
end
