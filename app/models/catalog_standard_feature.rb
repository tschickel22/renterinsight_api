# frozen_string_literal: true

# One line from a standards sheet ("Wrapped Shaker Cabinets" under Kitchen).
class CatalogStandardFeature < ApplicationRecord
  belongs_to :price_book, class_name: 'CatalogPriceBook', foreign_key: :catalog_price_book_id,
                          inverse_of: :standard_features

  validates :category, :name, presence: true
end
