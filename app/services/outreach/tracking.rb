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

    # A short form for texts: the long signed token alone ran about 130
    # characters and pushed every text into a third segment.
    SHORT = /\A(\d+)-(\d+)-([a-f0-9]{12})\z/

    def short_video_url(target, item)
      "#{Messaging::TrackingUrl.base}/o/v/#{target.id}-#{item.id}-#{short_mac(target.id, item.id)}"
    end

    def short_mac(target_id, item_id)
      OpenSSL::HMAC.hexdigest('SHA256', Rails.application.key_generator.generate_key('outreach_short_links'), "#{target_id}-#{item_id}")[0, 12]
    end

    # [target_id, item_id] from either form, or nil.
    def read_video(token)
      if (m = token.to_s.match(SHORT))
        return ActiveSupport::SecurityUtils.secure_compare(m[3], short_mac(m[1], m[2])) ? [m[1].to_i, m[2].to_i] : nil
      end

      read(token)
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
