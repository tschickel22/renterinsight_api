# frozen_string_literal: true

# Publishes a reviewed price book. The Champion Topeka book took about a
# minute, too long for a web request, so the admin sees "Publishing" and the
# page polls book.metadata['publishing'] until it is done or failed.
class CatalogPriceBookPublishJob < ApplicationJob
  queue_as :default

  def perform(book_id, user_id)
    book = CatalogPriceBook.find_by(id: book_id)
    user = User.find_by(id: user_id)
    return unless book && user && book.editable?

    mark(book, 'state' => 'running', 'started_at' => Time.current.iso8601)
    counts = Catalog::PriceBooks::Publisher.new(book, by: user).call
    mark(book.reload, 'state' => 'done', 'finished_at' => Time.current.iso8601, 'counts' => counts)
  rescue Catalog::PriceBooks::Publisher::NotReady, ActiveRecord::RecordInvalid, ArgumentError => e
    mark(book.reload, 'state' => 'failed', 'error' => e.message, 'finished_at' => Time.current.iso8601) if book
  rescue StandardError => e
    mark(book.reload, 'state' => 'failed', 'error' => "Publishing stopped: #{e.message}", 'finished_at' => Time.current.iso8601) if book
    raise
  end

  private

  def mark(book, state)
    book.update_columns(metadata: book.metadata.merge('publishing' => state), updated_at: Time.current)
  end
end
