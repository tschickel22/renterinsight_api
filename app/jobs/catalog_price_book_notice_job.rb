# frozen_string_literal: true

# Prices a newly published book's changes for each dealer and notifies them.
class CatalogPriceBookNoticeJob < ApplicationJob
  queue_as :low

  def perform(book_id)
    book = CatalogPriceBook.find_by(id: book_id)
    Truebuild::PriceBookNotifier.deliver(book) if book&.published?
  end
end
