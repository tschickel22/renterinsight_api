# frozen_string_literal: true

# After a price book correction: re-prices the saved designs of every dealer
# with designs on that manufacturer, so the rep sees today's price.
class CatalogPriceCorrectionJob < ApplicationJob
  queue_as :default

  def perform(book_id)
    book = CatalogPriceBook.find_by(id: book_id)
    return unless book

    company_ids = TruebuildDesign.joins(:variant).where(catalog_plan_variants: { manufacturer_id: book.manufacturer_id })
                                 .distinct.pluck(:company_id)
    Company.where(id: company_ids).find_each { |company| Truebuild::DesignRepricer.call(company) }
  end
end
