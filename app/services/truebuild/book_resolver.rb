# frozen_string_literal: true

module Truebuild
  # Which price book a dealer prices a model from. The plant's published book,
  # unless the dealer reviews new books and has not adopted this one yet: then
  # the newest earlier book they did adopt (or that was published before they
  # started reviewing), so their prices do not move until they say so.
  module BookResolver
    module_function

    def book_for(company, variant)
      factory_id = variant.catalog_plan.factory_id
      current = CatalogPriceBook.current_for(manufacturer_id: variant.manufacturer_id, factory_id: factory_id)
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
