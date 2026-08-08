# frozen_string_literal: true

module Websites
  # Where to send a visitor who wants to book time with the dealer.
  #
  # Most specific wins, mirroring how SMS provider resolution already works:
  # the rep who will actually take the appointment, then the lot, then head
  # office. A rep's own link is preferred because a buyer booking with a named
  # person converts better than one booking with a dealership, and User#booking_url
  # already exists and already holds their Calendly.
  #
  # Returns nil rather than a placeholder when nothing is configured. The caller
  # falls back to the intake form, which every site has, so a dealer who has set
  # up no scheduler still captures the lead instead of hitting a dead end.
  module BookingUrl
    # Where a location or company keeps it. Read through the operational
    # settings resolver rather than a column, since that is where the rest of a
    # dealer's operating preferences live.
    SETTING_KEY = 'booking_url'

    module_function

    # @param company [Company]
    # @param location [Location, nil]
    # @param user [User, nil] the rep the conversation is assigned to
    # @return [String, nil]
    def resolve(company:, location: nil, user: nil)
      candidates = [
        user&.try(:booking_url),
        location_setting(location),
        company_setting(company)
      ]

      candidates.map { |value| normalize(value) }.compact.first
    end

    # Reads BOTH key spellings.
    #
    # LocationSettingsResolver reads the Location scope with key 'operational'
    # only, while the Company Settings UI writes 'operational_settings'. Company
    # scope has a fallback for that; Location scope does not, so a booking URL
    # saved at location level under the newer spelling would silently resolve to
    # nothing and the concierge would look broken with no error anywhere.
    def location_setting(location)
      return nil if location.nil?

      %w[operational operational_settings].each do |key|
        value = Setting.get('Location', location.id, key).to_h[SETTING_KEY]
        return value if value.present?
      end
      nil
    rescue StandardError
      nil
    end

    def company_setting(company)
      return nil if company.nil?

      %w[operational_settings operational].each do |key|
        value = Setting.get('Company', company.id, key).to_h[SETTING_KEY]
        return value if value.present?
      end
      nil
    rescue StandardError
      nil
    end

    # A scheduler link a dealer pasted from their browser may arrive without a
    # scheme, and an anchor without one is treated as a relative path, which
    # would send the visitor to a page on the dealer's own site that does not
    # exist.
    def normalize(value)
      url = value.to_s.strip
      return nil if url.blank?
      return url if url.start_with?('http://', 'https://')

      "https://#{url}"
    end
  end
end
