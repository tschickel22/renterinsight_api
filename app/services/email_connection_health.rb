# frozen_string_literal: true

# A mailbox the rep connected on purpose is part of the message. When it
# breaks, the send has to fail and say so.
#
# The tempting alternative is to let the provider waterfall take over and send
# from the location, company, or platform mailbox instead. That is worse than
# failing: it looks like success, the customer gets mail from the wrong person,
# replies go somewhere the rep is not watching, and nobody ever learns the
# connection died. So a broken connection stays selected and the send fails
# attributably.
#
# The waterfall is still correct for a user who never connected a mailbox at
# all. "Never configured" falls back; "configured but broken" fails loudly.
class EmailConnectionHealth
  class << self
    # Mark a connection as needing re-auth and notify its owner, but only when
    # the provider error actually means the token is dead. Ordinary failures
    # (bad recipient, rate limit, network blip) must not nag the user to
    # reconnect a mailbox that is fine.
    def flag!(connection, error)
      return false unless connection.is_a?(UserEmailConnection)

      message = message_for(error)
      return false if message.blank?
      return false unless reauth_error?(message)
      # Already flagged and not since cleared, so skip the duplicate notification.
      return false if connection.needs_reauth?

      connection.mark_needs_reauth!(message)
      Rails.logger.warn(
        "[EmailConnectionHealth] UserEmailConnection ##{connection.id} needs reauth; notified user #{connection.user_id}"
      )
      true
    rescue => e
      Rails.logger.error "[EmailConnectionHealth] Failed to flag connection: #{e.message}"
      false
    end

    # The controllers thread the originating connection through the email
    # config as _sourceConnectionType / _sourceConnectionId.
    def flag_from_config!(config, error)
      return false unless config.is_a?(Hash)

      source_type = config['_sourceConnectionType'] || config[:_sourceConnectionType]
      source_id   = config['_sourceConnectionId']   || config[:_sourceConnectionId]
      return false unless source_type == 'UserEmailConnection' && source_id.present?

      flag!(UserEmailConnection.find_by(id: source_id), error)
    end

    # Background senders don't carry a config hash, but they do know which user
    # they were sending as.
    def flag_for_user!(user, error)
      return false unless user.respond_to?(:default_email_connection)

      flag!(user.default_email_connection, error)
    end

    def reauth_error?(message)
      UserEmailConnection::REAUTH_ERROR_PATTERNS.any? { |re| message.to_s =~ re }
    end

    private

    def message_for(error)
      error.respond_to?(:message) ? error.message : error.to_s
    end
  end
end
