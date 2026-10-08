# frozen_string_literal: true

module Truebuild
  # Which published book a model's options come from. The newest book wins
  # for what it covers: the base price from the newest book that prices the
  # model (BookResolver), the options from the newest book that carries
  # options for the model's series or its plant. Decatur's one-page Prime
  # order form is a book of options and finishes with no base prices; without
  # this it would never reach a Prime home, whose base comes from the Topeka
  # package.
  #
  # Rows are never merged across books: a newer sheet that renames options
  # ("OSB Wrap <=68' SW" became "OSB Wrap (<=68') SINGLEWIDE") must not leave
  # the old names offered beside the new ones.
  module OptionSource
    module_function

    # The newest published book with options for this model: what its option
    # costs come from. Falls back to the book that prices its base.
    def current_for(variant)
      covering(variant, CatalogPriceBook.published).first || BookResolver.current_for(variant)
    end

    # The options book a dealer's option RETAIL comes from, held back the
    # same way as the base while they review a new book: the newest earlier
    # book with options for this model that they accepted, or that came
    # before they started reviewing. A new plant's sheet replaces options
    # another plant's book carried, so the plant's own supersedes chain
    # cannot answer this; the books covering the model can.
    def book_for(company, variant)
      current = current_for(variant)
      return current unless current && BookResolver.holds_for_review?(company, variant.manufacturer_id)
      return current if acceptable?(company, current)

      earlier = covering(variant, CatalogPriceBook.where(status: %w[published superseded]))
                .where('published_at < ?', current.published_at)
      earlier.detect { |b| acceptable?(company, b) } || current
    end

    def acceptable?(company, book)
      adoption = company.dealer_price_book_adoptions.find_by(catalog_price_book_id: book.id)
      adoption.nil? || adoption.status == 'adopted'
    end

    # Books with options for this model's series, or for its plant, newest first.
    def covering(variant, books)
      plan = variant.catalog_plan
      books = books.where(manufacturer_id: variant.manufacturer_id)
      scope = books.where(id: CatalogOptionPrice.where(series: plan.series).select(:catalog_price_book_id))
      if plan.factory_id
        scope = scope.or(books.where(factory_id: plan.factory_id, id: CatalogOptionPrice.select(:catalog_price_book_id)))
      end
      scope.order(published_at: :desc, id: :desc)
    end

    # The rows of a book that apply to this model.
    def offered(book, variant, construction: nil, option_ids: nil)
      return [] unless book

      rows = book.option_prices.includes(option: :group)
      rows = rows.where(catalog_option_id: option_ids) if option_ids
      rows.to_a.select { |op| op.applies_to?(variant, construction: construction) }
    end
  end
end
