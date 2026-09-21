# frozen_string_literal: true

module Meta
  # Exchanges a Meta token for a fresh long-lived one and works out when it
  # actually expires.
  #
  # Four call sites each carried the same line:
  #
  #   token_expires_at: Time.current + resp['expires_in'].to_i.seconds
  #
  # Graph omits `expires_in` for a token that does not expire, which is what a
  # long-lived token exchanged again usually is. `nil.to_i` is 0, so every
  # refresh stamped the expiry as the moment the button was pressed and the
  # screen said "Expired, refresh required" the instant it finished. Pressing
  # it again did the same thing, which is what made it look like nothing
  # happened. Seen on production integration 2 on 2026-09-21:
  # token_expires_at and updated_at one millisecond apart.
  #
  # So `expires_in` is only trusted when it is there. Otherwise Graph is asked
  # outright with debug_token, where `expires_at: 0` means never. Never is
  # stored as nil, which every reader already treats as "not expiring" rather
  # than "expired long ago".
  class TokenRefresh
    Result = Struct.new(:access_token, :expires_at, keyword_init: true)

    class << self
      # Exchanges, then resolves the expiry. Raises MetaGraphApi::Error, which
      # callers already handle, so an expired token still surfaces as a
      # reconnect rather than a silent no-op.
      def call(source_token)
        response = MetaGraphApi.exchange_token(source_token)
        token = response['access_token'].presence || source_token

        Result.new(access_token: token, expires_at: expires_at_for(response, token))
      end

      # The expiry of a token we are not replacing, for repairing a row that
      # was stamped with a wrong one.
      def expires_at_of(token)
        expires_at_for({}, token)
      end

      private

      def expires_at_for(response, token)
        seconds = response['expires_in'].to_i
        return Time.current + seconds.seconds if seconds.positive?

        debug_expiry(token)
      end

      # nil means "does not expire", which is the normal answer for a page
      # token and for a long-lived user token Meta chose not to age out.
      def debug_expiry(token)
        data = MetaGraphApi.debug_token(token)['data']
        return nil unless data.is_a?(Hash)

        expires_at = data['expires_at'].to_i
        return nil unless expires_at.positive?

        Time.zone.at(expires_at)
      rescue MetaGraphApi::Error => e
        # Worth nothing more than a note: the exchange itself succeeded, and a
        # missing expiry is not a reason to throw the new token away.
        Rails.logger.warn "[Meta::TokenRefresh] debug_token failed: #{e.message}"
        nil
      end
    end
  end
end
