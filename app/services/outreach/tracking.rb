# frozen_string_literal: true

module Outreach
  # Links in outreach messages (backlog E105): a video link that records the
  # click, and an unsubscribe page that needs no sign in.
  module Tracking
    VERIFIER = :proactive_outreach

    module_function

    def verifier
      Rails.application.message_verifier(VERIFIER)
    end

    def video_url(target, item)
      "#{Messaging::TrackingUrl.base}/o/v/#{sign([target.id, item.id])}"
    end

    # Their website checkup (OutreachTrackingController#report).
    def report_url(target)
      "#{Messaging::TrackingUrl.base}/o/r/#{sign([target.id, 'report'])}"
    end

    def unsubscribe_url(target)
      "#{Messaging::TrackingUrl.base}/o/u/#{sign([target.id, 'unsubscribe'])}"
    end

    # A signed value can hold characters that do not belong in a web address.
    def sign(value)
      Base64.urlsafe_encode64(verifier.generate(value), padding: false)
    end

    def read(token)
      verifier.verified(Base64.urlsafe_decode64(token.to_s))
    rescue ArgumentError
      nil
    end
  end
end
