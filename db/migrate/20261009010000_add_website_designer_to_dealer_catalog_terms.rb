# frozen_string_literal: true

# Whether buyers can design homes on the dealer's websites. A dealer can use
# TrueBuild in house (the Deal Sheet, quotes, the factory PO) while its
# website lists the homes without the designer or its prices, as Factory
# Direct does while its factories are set up. On by default: every dealer
# offering it today keeps it.
class AddWebsiteDesignerToDealerCatalogTerms < ActiveRecord::Migration[8.0]
  def change
    add_column :dealer_catalog_terms, :website_designer, :boolean, null: false, default: true
  end
end
