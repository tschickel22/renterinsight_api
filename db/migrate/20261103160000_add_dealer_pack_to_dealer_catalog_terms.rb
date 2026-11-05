# frozen_string_literal: true

class AddDealerPackToDealerCatalogTerms < ActiveRecord::Migration[8.0]
  def change
    add_column :dealer_catalog_terms, :dealer_pack, :decimal, precision: 10, scale: 2
  end
end
