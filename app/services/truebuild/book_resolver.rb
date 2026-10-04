# frozen_string_literal: true

module Truebuild
  # Which price book a dealer's RETAIL comes from. The plant's published book,
  # unless the dealer reviews new books and has not adopted this one yet: then
  # the newest earlier book they did adopt (or that was published before they
  # started reviewing), so their prices do not move until they say so. Cost
  # always comes from the current book (current_for): the factory invoices it.
  module BookResolver
    module_function

    # The newest published book that prices this model: where cost always
    # comes from. Decided by the price row, not the plan's plant, so a
    # package covering two plants, or a later book for just one of them,
    # never leaves a model unpriced.
    def current_for(variant)
      CatalogPriceBook.published.where(manufacturer_id: variant.manufacturer_id)
                      .where(id: CatalogVariantPrice.where(catalog_plan_variant_id: variant.id).select(:catalog_price_book_id))
                      .order(published_at: :desc, id: :desc).first ||
        CatalogPriceBook.current_for(manufacturer_id: variant.manufacturer_id, factory_id: variant.catalog_plan.factory_id)
    end

    # The book the dealer's retail comes from.
    def book_for(company, variant)
      current = current_for(variant)
      return nil unless current
      return current unless holds_for_review?(company, variant.manufacturer_id)

      adoption = company.dealer_price_book_adoptions.find_by(catalog_price_book_id: current.id)
      return current if adoption.nil? || adoption.status == 'adopted'

      accepted_before(company, current) || current
    end

    # The newest book older than this one that the dealer accepted, or that
    # was published before they started reviewing. Nil when there is none.
    def accepted_before(company, book)
      book = book.supersedes
      while book
        a = company.dealer_price_book_adoptions.find_by(catalog_price_book_id: book.id)
        return book if a.nil? || a.status == 'adopted'

        book = book.supersedes
      end
      nil
    end

    def holds_for_review?(company, manufacturer_id)
      DealerCatalogTerm.effective(company, manufacturer_id).price_update_policy == 'review'
    end
  end
end
