# frozen_string_literal: true

# What a buyer sees in TrueBuild, separate from what the dealer can sell.
# A purchase order needs every option; a buyer choosing finishes does not.
class AddBuyerViewToDealerCatalogTerms < ActiveRecord::Migration[8.0]
  def change
    add_column :dealer_catalog_terms, :buyer_view, :string, null: false, default: 'curated'
    add_column :dealer_catalog_terms, :buyer_featured_option_ids, :jsonb, null: false, default: []
    add_column :dealer_catalog_terms, :buyer_hidden_option_ids, :jsonb, null: false, default: []
    add_column :dealer_catalog_terms, :buyer_hidden_groups, :jsonb, null: false, default: []
  end
end
