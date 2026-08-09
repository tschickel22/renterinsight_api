# frozen_string_literal: true

module Websites
  # Carries what the visitor already told us into the dealer's scheduler.
  #
  # We do not integrate with Calendly or anyone else, and we do not need to.
  # Every mainstream scheduler reads name and email off the query string, which
  # is a documented feature of theirs rather than a trick, so a buyer who has
  # already given the assistant their details lands on a form that is filled in.
  #
  # This is what makes it defensible to ask for a name before showing the
  # calendar. Without prefill the buyer types the same two things twice, and the
  # second time they are looking at a booking page that a moment ago they were
  # ready to complete. With it, asking costs them nothing and we keep the lead
  # even when they never finish booking.
  #
  # Unknown scheduler, or nothing to add, and the URL comes back untouched. A
  # guessed parameter name is worse than none: it shows up as a stray field or
  # an error on somebody else's booking page, which is a dealer's first
  # impression of a buyer.
  module BookingPrefill
    # Documented prefill parameters, by scheduler. Keys are what we hold, values
    # are what that provider calls it.
    #
    # Anchored to a host boundary, not matched as a substring. An unanchored
    # /cal\.com/ also matches savvycal.com, which would have sent SavvyCal
    # cal.com's parameter names and silently prefilled nothing.
    #
    # The leading (?:\A|\.) is what allows the per-account subdomains most of
    # these use, so meetings.hubspot.com and summitpark.acuityscheduling.com
    # both resolve without listing every tenant.
    PROVIDERS = [
      { match: /(?:\A|\.)calendly\.com\z/i, full_name: 'name', email: 'email' },
      { match: /(?:\A|\.)hubspot\.com\z/i,
        first_name: 'firstName', last_name: 'lastName', email: 'email' },
      { match: /(?:\A|\.)(?:acuityscheduling|squarespacescheduling)\.com\z/i,
        first_name: 'firstName', last_name: 'lastName', email: 'email', phone: 'phone' },
      { match: /(?:\A|\.)savvycal\.com\z/i, full_name: 'display_name', email: 'email' },
      { match: /(?:\A|\.)cal\.com\z/i, full_name: 'name', email: 'email' },
      { match: /(?:\A|\.)youcanbook\.me\z/i, full_name: 'NAME', email: 'EMAIL' },
      { match: /(?:\A|\.)zcal\.co\z/i, full_name: 'name', email: 'email' }
    ].freeze

    module_function

    # @param url [String, nil] the dealer's scheduler, from BookingUrl
    # @param name [String, nil] whatever the visitor gave the assistant
    # @param email [String, nil]
    # @param phone [String, nil]
    # @return [String, nil] the same URL, prefilled where the provider supports it
    def apply(url, name: nil, email: nil, phone: nil)
      return url if url.blank?

      values = { full_name: name.to_s.strip.presence, email: email.to_s.strip.presence,
                 phone: phone.to_s.strip.presence }.compact
      return url if values.empty?

      uri = URI.parse(url)
      return url unless uri.is_a?(URI::HTTP)

      provider = PROVIDERS.find { |p| uri.host.to_s.match?(p[:match]) }
      return url if provider.nil?

      params = existing_params(uri)
      merge_params!(params, provider, values)

      uri.query = params.empty? ? nil : URI.encode_www_form(params)
      uri.to_s
    rescue URI::InvalidURIError, ArgumentError => e
      # A dealer can paste anything into this field, and a scheduler link that
      # still works unprefilled beats an exception on the way to the calendar.
      Rails.logger.warn("[BookingPrefill] #{e.class}: #{e.message}")
      url
    end

    def existing_params(uri)
      URI.decode_www_form(uri.query.to_s).to_h
    rescue StandardError
      {}
    end

    # Never overwrites a parameter the dealer put in the link themselves. They
    # know something about their own booking flow that we do not.
    def merge_params!(params, provider, values)
      pairs = {}

      if provider[:full_name] && values[:full_name]
        pairs[provider[:full_name]] = values[:full_name]
      elsif provider[:first_name] && values[:full_name]
        first, last = split_name(values[:full_name])
        pairs[provider[:first_name]] = first
        pairs[provider[:last_name]] = last if provider[:last_name] && last.present?
      end

      pairs[provider[:email]] = values[:email] if provider[:email] && values[:email]
      pairs[provider[:phone]] = values[:phone] if provider[:phone] && values[:phone]

      pairs.each { |key, value| params[key] = value unless params.key?(key) }
    end

    # Deliberately naive, and only used by providers that insist on two fields.
    # A single-word name becomes a first name with no surname rather than being
    # split into something the visitor did not say.
    def split_name(full)
      first, rest = full.split(/\s+/, 2)
      [first, rest]
    end
  end
end
