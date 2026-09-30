# frozen_string_literal: true

# What changed for this dealer between the book they price from and the new
# one, at their own markup, so the review screen reads a stored summary
# instead of diffing two books on every page load.
class AddSummaryToDealerPriceBookAdoptions < ActiveRecord::Migration[8.0]
  def change
    add_column :dealer_price_book_adoptions, :summary, :jsonb, default: {}, null: false
    add_column :dealer_price_book_adoptions, :notified_at, :datetime
    add_reference :dealer_price_book_adoptions, :previous_book, foreign_key: { to_table: :catalog_price_books }
  end
end
