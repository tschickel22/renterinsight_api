# frozen_string_literal: true

module Websites
  # Swaps the made-up contact details a template ships with for the dealer's
  # own, when a site is created from it.
  #
  # The templates carry a full fake identity so a preview reads like a real
  # site: (555) numbers, info@yourdealership.com, "123 Dealer Drive, Your City,
  # ST 12345", "Your Dealership Name". The footer, map and contact button were
  # already filled from the company, but text blocks and page titles were not,
  # so a published contact page could still list a phone that rings nowhere.
  # Crawlers and AI assistants read that text and quote it, and it contradicts
  # the real details in the site's markup.
  #
  # A value the company does not have is removed rather than left fake: an
  # empty "Phone:" line is honest, a 555 number is not.
  class TemplatePlaceholders
    STREETS = /\b\d{1,5} (?:Dealer Drive|Coastal Blvd|Mountain Rd|Community Drive|Modern Way)\b/
    CITY_LINE = /Your City, ST \d{5}/
    PHONE = /\(555\) \d{3}-\d{4}/
    TEL = /tel:555\d{7}/
    EMAIL = /\b[\w.+-]+@your(?:dealership|community|company|business)\.com\b/
    NAME = /Your (?:Dealership|Community|Company|Business) Name/

    def initialize(company:, location: nil)
      @company = company
      @place = location&.try(:address_line1).presence ? location : company
    end

    # Deep-walks hashes, arrays and strings, returning a scrubbed copy.
    def scrub(value)
      case value
      when String then scrub_string(value)
      when Array then value.map { |v| scrub(v) }
      when Hash then value.to_h.transform_values { |v| scrub(v) }
      else value
      end
    end

    private

    def scrub_string(text)
      return text unless text.match?(Regexp.union(STREETS, CITY_LINE, PHONE, TEL, EMAIL, NAME))

      text
        .gsub(NAME) { name }
        .gsub(STREETS) { street }
        .gsub(CITY_LINE) { city_line }
        .gsub(TEL) { phone_digits.present? ? "tel:#{phone_digits}" : '' }
        .gsub(PHONE) { phone }
        .gsub(EMAIL) { email }
        # "123 Dealer Drive, Your City" with both halves gone leaves ", ".
        .gsub(/\A,\s*|\s*,\s*\z/, '')
    end

    def name
      @company&.name.to_s
    end

    def street
      [@place.try(:address_line1), @place.try(:address_line2)].compact_blank.join(', ')
    end

    def city_line
      locality = [@place.try(:city).presence, @place.try(:state).presence].compact.join(', ')
      [locality.presence, @place.try(:zip_code).presence].compact.join(' ')
    end

    def phone
      @place.try(:phone).presence || @company.try(:phone).to_s
    end

    def phone_digits
      phone.gsub(/\D/, '')
    end

    def email
      @place.try(:email).presence || @company.try(:email).to_s
    end
  end
end
