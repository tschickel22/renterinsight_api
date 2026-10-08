# frozen_string_literal: true

# A dealer's choice to leave prices off the factory PO it prints and emails
# (backlog E51): the factory bills from its own price list, and a figure
# from the Deal Sheet that disagrees with it only causes confusion.
class AddFactoryPoHidePricesToDealerCatalogTerms < ActiveRecord::Migration[8.0]
  def change
    add_column :dealer_catalog_terms, :factory_po_hide_prices, :boolean, null: false, default: false
  end
end
