# frozen_string_literal: true

module Assistant
  # What the website chat tells the page it sits on when Quinn turns a visitor
  # into a lead or books them a visit, so the page's own ad pixel (Meta, Google)
  # can count it. Without this a chat lead from an ad counted as nothing, while
  # the same person sending a form counted as a Lead.
  #
  # The browser fires them (the widget on a site we host, the embed line on a
  # dealer's own site). The id is the event id Meta uses to drop duplicates, so
  # a later server copy of the same event (Conversions API) can send the same
  # one. It is derived from the record, never the record id itself, so the page
  # learns nothing about how many leads the dealer has.
  module Conversions
    module_function

    def lead(lead)
      lead ? event('Lead', "lead:#{lead.id}") : nil
    end

    # Only a new visit. Moving or cancelling one is not a conversion.
    def schedule(visit)
      visit ? event('Schedule', "visit:#{visit.id}") : nil
    end

    def event(name, key)
      { name: name, id: "dt-#{OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, key)[0, 24]}" }
    end
  end
end
