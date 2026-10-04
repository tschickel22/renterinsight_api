# frozen_string_literal: true

# Extracts one price book file, then, once no file in the book is still
# waiting or running, reconciles the book (match to the catalog, compare with
# the published book) and hands it to the admin for review.
class CatalogPriceBookExtractionJob < ApplicationJob
  queue_as :low

  def perform(document_id)
    doc = CatalogPriceBookDocument.find_by(id: document_id)
    return if doc.nil?

    Catalog::PriceBooks::DocumentExtractor.new(doc).call

    book = doc.price_book
    book.with_lock do
      waiting = book.documents.where(extraction_status: %w[pending running]).exists?
      if !waiting && book.status == 'extracting'
        Catalog::PriceBooks::Reconciler.new(book).call
        book.update!(status: 'in_review')
      end
    end
  end
end
