# frozen_string_literal: true

module Ses
  # Single source of truth for which SES region we operate in.
  #
  # SES identities are per-region: a domain verified in us-east-1 does not exist in
  # us-west-2. Before this existed, identity creation defaulted to us-west-2 while sending
  # resolved to us-east-1 through CommunicationSettingsService, so with AWS_REGION unset
  # every verified domain would have been created in a region its mail never sent from and
  # would have failed to send with no obvious cause.
  #
  # The fallback matches the sending path's existing default so behaviour does not change
  # for anyone. Set AWS_REGION explicitly rather than relying on it.
  module Region
    DEFAULT = 'us-east-1'

    def self.current
      ENV['AWS_REGION'].presence || DEFAULT
    end
  end
end
