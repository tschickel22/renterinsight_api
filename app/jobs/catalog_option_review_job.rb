# frozen_string_literal: true

# Claude's review of a published book's options (Catalog::PriceBooks::OptionReview).
class CatalogOptionReviewJob < ApplicationJob
  queue_as :low

  def perform(book_id)
    book = CatalogPriceBook.find_by(id: book_id)
    return unless book&.status == 'published'

    Catalog::PriceBooks::OptionReview.new(book).call
  rescue Catalog::PriceBooks::ClaudeClient::Error => e
    Rails.logger.warn("CatalogOptionReviewJob #{book_id}: #{e.message}")
    book&.update!(metadata: book.metadata.merge('option_review' => { 'error' => e.message.first(300), 'ran_at' => Time.current.iso8601 }))
  end

  # A published book Claude has not reviewed yet is queued the first time its
  # options are shown, so books published before the review existed catch up
  # without anyone starting it.
  def self.once(book)
    return if book.nil? || book.metadata.to_h.key?('option_review')
    return unless Rails.cache.write("catalog:option_review:queued:#{book.id}", true, expires_in: 6.hours, unless_exist: true)

    perform_later(book.id)
  end
end
