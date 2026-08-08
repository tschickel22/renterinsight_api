# frozen_string_literal: true

module Concierge
  # Turns "3 bedroom under 80k" into the filter params the public inventory
  # endpoint already accepts.
  #
  # Deliberately not a model call. The vocabulary of a home search is small and
  # almost entirely numeric, so a handful of patterns covers the overwhelming
  # majority of what a buyer types, at no cost and with no chance of inventing a
  # home that does not exist. That last part matters more than the money: a model
  # asked to answer "what do you have under $80k" from prose can hallucinate a
  # floor plan, where a query cannot.
  #
  # Returns nil when nothing matched, which is the signal to fall through to the
  # model rather than guess.
  class InventoryQuery
    # Words that mean the visitor is looking for stock rather than asking about
    # the business. Checked before the numbers, because "how many bedrooms do
    # your homes have" is a question, not a search.
    SEARCH_HINTS = /\b(show|find|looking for|do you have|got any|any\b.*\bhomes?|available|in stock|inventory|browse|search|list)\b/i

    BEDROOMS = /\b(\d)\s*(?:\+|or more)?\s*(?:bed|bedroom|br|bd)s?\b/i
    BATHROOMS = /\b(\d(?:\.\d)?)\s*(?:bath|bathroom|ba)s?\b/i
    SQFT = /\b(\d{3,5})\s*(?:sq\.?\s*ft|square feet|sqft)\b/i

    # $80k, 80k, $80,000, under 80000. The k suffix is how people actually
    # write prices in this market.
    PRICE = /\$?\s*(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?\s*k\b|\d{4,7})/i
    UNDER = /\b(under|below|less than|cheaper than|max|up to|budget of)\b/i
    OVER = /\b(over|above|more than|at least|starting at|minimum)\b/i

    SECTIONS = {
      /\bsingle[\s-]?wide\b/i => '1',
      /\bdouble[\s-]?wide\b/i => '2',
      /\btriple[\s-]?wide\b/i => '3'
    }.freeze

    def initialize(text)
      @text = text.to_s
    end

    # @return [Hash, nil] filter params, or nil when this is not a stock question
    def call
      filters = {}

      if (m = @text.match(BEDROOMS))
        filters[:bedrooms] = m[1]
      end
      if (m = @text.match(BATHROOMS))
        filters[:bathrooms] = m[1]
      end
      if (m = @text.match(SQFT))
        filters[:square_feet_min] = m[1]
      end
      SECTIONS.each { |pattern, value| filters[:sections] = value if @text.match?(pattern) }

      price = extract_price
      filters.merge!(price) if price.present?

      # A bare "do you have anything" is still a stock question and should list
      # inventory rather than be handed to the model.
      return filters if filters.any?
      return {} if @text.match?(SEARCH_HINTS)

      nil
    end

    private

    # Direction matters more than the number: "under 80k" and "over 80k" are
    # opposite searches and a filter that ignores the word is worse than none.
    def extract_price
      match = @text.match(PRICE)
      return nil if match.nil?

      amount = normalize_amount(match[1])
      return nil if amount.nil? || amount < 1_000

      before = @text[0...match.begin(0)]
      return { max_price: amount } if before.match?(UNDER)
      return { min_price: amount } if before.match?(OVER)

      # No direction given. A shopper who names one number almost always means
      # "around this, and not much more", so it reads as a ceiling.
      { max_price: amount }
    end

    def normalize_amount(raw)
      value = raw.to_s.downcase.delete(',').strip
      return (value.to_f * 1_000).round if value.end_with?('k')

      value.to_i
    rescue StandardError
      nil
    end
  end
end
