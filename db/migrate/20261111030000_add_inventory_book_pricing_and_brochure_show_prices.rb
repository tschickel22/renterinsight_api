# frozen_string_literal: true

# E98: whether inventory shows the deal sheet price worked out from the price
# book (company row; a manufacturer row can turn it off or on for one
# builder; nil means "as the company says", and on by default). A brochure's
# own choice to show or hide prices (nil follows its template). Both
# additive, so old and new code run side by side during the release.
class AddInventoryBookPricingAndBrochureShowPrices < ActiveRecord::Migration[8.0]
  def change
    add_column :dealer_catalog_terms, :inventory_book_pricing, :boolean
    add_column :brochures, :show_prices, :boolean
  end
end
