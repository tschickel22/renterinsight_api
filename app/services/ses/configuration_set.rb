# frozen_string_literal: true

module Ses
  # The SES configuration set every outbound message is tagged with.
  #
  # A configuration set is the only thing that makes SES publish bounce, complaint and
  # delivery events. Without one the send still succeeds and we simply never hear what
  # happened to it, which is the state campaign reporting was in: every send sat at "sent"
  # forever because nothing ever came back to move it.
  #
  # Tagging is safe before the set exists. AwsSesDelivery retries without the header rather
  # than letting a missing set take transactional mail down with it, so the name can be
  # resolved here unconditionally and provisioned later.
  module ConfigurationSet
    DEFAULT = 'platform-email-events'

    # AWS_SES_CONFIGURATION_SET is accepted because that is the name .env.example and the
    # docs have always used, while the code only ever read SES_CONFIGURATION_SET. Anyone
    # who followed the documentation set a variable nothing consumed, and got silence from
    # a pipeline that looked configured.
    def self.current
      ENV['SES_CONFIGURATION_SET'].presence ||
        ENV['AWS_SES_CONFIGURATION_SET'].presence ||
        DEFAULT
    end
  end
end
