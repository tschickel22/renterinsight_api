# frozen_string_literal: true

# The published Champion Topeka book labelled every plan Topeka, including
# Prime, which its own "Prime - Decatur factory" tab says is built at Decatur.
# Catalog::PriceBooks::Plants now labels series from plant-named tabs at
# publish; this applies it to books already published. Labels only: books
# are chosen by price row (Truebuild::BookResolver), so no price moves.
class LabelCatalogPlanPlants < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:catalog_price_books)

    [Factory, CatalogPlan, CatalogPriceBook, CatalogPriceBookDocument].each(&:reset_column_information)
    CatalogPriceBook.where(status: 'published').find_each { |book| Catalog::PriceBooks::Plants.label_series(book) }
  end

  def down; end
end
