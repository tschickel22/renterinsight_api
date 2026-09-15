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
#
# Shared senders
# --------------
# A Location, Company or Platform sender lives on a `communications` Setting
# row rather than a UserEmailConnection, so nobody owned its failures and they
# only ever reached the log. Factory Direct's Auburn mailbox sat on a revoked
# Microsoft grant for over a day while its lead emails failed, and its
# notification emails had been refused by SES for a week.
#
# A failure a person has to fix now leaves a marker on that row and tells the
# people who can act on it: the mailbox owner, the admins for that level, the
# user who was sending, and the teammate the email was meant for. Each is told
# once per outage. The marker is kept per channel because CommunicationService
# and the notification mailer resolve their sender differently; one of them
# working must not clear the other and re-notify everyone on its next failure.
class EmailConnectionHealth
  HEALTH_KEY = 'senderHealth'
  CHANNELS = %w[mailbox system_mail].freeze

  # Errors meaning the sender itself is misconfigured, as opposed to one bad
  # recipient or a rate limit. Retrying never fixes these; a person has to.
  SENDER_CONFIG_ERROR_PATTERNS = [
    /Email address is not verified/i,
    /identities failed the check/i,
    /SignatureDoesNotMatch/i,
    /InvalidClientTokenId/i,
    /security token included in the request is invalid/i,
    /not authorized to perform:?\s*ses:/i,
    /Lifetime validation failed/i,
    /Username and Password not accepted/i,
    /Authentication unsuccessful/i,
    /\A535\b/
  ].freeze

  # Same order ApplicationMailer#default_from_address reads them in.
  FROM_FIELDS = %w[from_address fromAddress fromEmail from_email].freeze

  PROVIDER_LABELS = {
    'oauth_microsoft' => 'Outlook/Microsoft 365',
    'oauth_outlook'   => 'Outlook/Microsoft 365',
    'oauth_google'    => 'Gmail',
    'oauth_gmail'     => 'Gmail',
    'aws_ses'         => 'Amazon SES',
    'sendgrid'        => 'SendGrid',
    'smtp'            => 'SMTP'
  }.freeze

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

    def actionable_error?(message)
      reauth_error?(message) || SENDER_CONFIG_ERROR_PATTERNS.any? { |re| message.to_s =~ re }
    end

    # A CommunicationService send failed. Blame the level it actually resolved
    # to: the rep's own mailbox when they have one, otherwise the Setting scope
    # that supplied the provider.
    def flag_send_failure!(error:, user: nil, communicable: nil, to_address: nil)
      return flag_for_user!(user, error) if own_mailbox?(user)

      company, location = context_of(communicable)
      scope_type, scope_id = sender_scope(company: company, location: location, fields: %w[provider])
      return false unless scope_type

      flag_shared!(
        scope_type: scope_type, scope_id: scope_id, error: error, channel: 'mailbox',
        company: company, location: location, sending_user: user,
        affected_user: internal_user(company, to_address)
      )
    rescue => e
      Rails.logger.error "[EmailConnectionHealth] Failed to flag send failure: #{e.message}"
      false
    end

    def clear_send_failure!(user: nil, communicable: nil)
      return false if own_mailbox?(user)

      company, location = context_of(communicable)
      scope_type, scope_id = sender_scope(company: company, location: location, fields: %w[provider])
      return false unless scope_type

      clear_shared!(scope_type: scope_type, scope_id: scope_id, channel: 'mailbox')
    rescue => e
      Rails.logger.error "[EmailConnectionHealth] Failed to clear send failure: #{e.message}"
      false
    end

    # NotificationMailer sends from the location, company or platform From
    # address over the platform's delivery method, so the From level is the
    # one to blame when the provider refuses it.
    def flag_system_mail_failure!(notification:, recipient:, error:)
      company, location = notification_context(notification)
      scope_type, scope_id = sender_scope(company: company, location: location, fields: FROM_FIELDS)
      return false unless scope_type

      flag_shared!(
        scope_type: scope_type, scope_id: scope_id, error: error, channel: 'system_mail',
        company: company, location: location, affected_user: recipient
      )
    rescue => e
      Rails.logger.error "[EmailConnectionHealth] Failed to flag notification email failure: #{e.message}"
      false
    end

    def clear_system_mail_failure!(notification:)
      company, location = notification_context(notification)
      scope_type, scope_id = sender_scope(company: company, location: location, fields: FROM_FIELDS)
      return false unless scope_type

      clear_shared!(scope_type: scope_type, scope_id: scope_id, channel: 'system_mail')
    rescue => e
      Rails.logger.error "[EmailConnectionHealth] Failed to clear notification email failure: #{e.message}"
      false
    end

    # Record a failure against a shared sender and notify whoever has not yet
    # heard about this outage. The row is locked so two processes failing at
    # the same moment cannot both decide they are first.
    def flag_shared!(scope_type:, scope_id:, error:, channel: 'mailbox', company: nil, location: nil,
                     sending_user: nil, affected_user: nil)
      message = message_for(error)
      return false if message.blank? || !actionable_error?(message)
      raise ArgumentError, "unknown sender channel #{channel}" unless CHANNELS.include?(channel)

      location ||= Location.find_by(id: scope_id) if scope_type == 'Location'
      company  ||= location&.company || (Company.find_by(id: scope_id) if scope_type == 'Company')

      to_notify = []
      email_cfg = nil
      Setting.transaction do
        setting = shared_setting(scope_type, scope_id)
        next unless setting

        setting.lock!
        data = parse(setting.value)
        email_cfg = data['email']
        next unless email_cfg.is_a?(Hash)

        health = email_cfg[HEALTH_KEY].is_a?(Hash) ? email_cfg[HEALTH_KEY] : (email_cfg[HEALTH_KEY] = {})
        entry = health[channel].is_a?(Hash) ? health[channel] : nil
        notified = Array(entry&.dig('notifiedUserIds')).map(&:to_i)

        # The owner and admins hear at the start of an outage. After that only a
        # sender or recipient who has not been told yet is new.
        candidates = if entry
                       [sending_user, affected_user].select { |u| u.is_a?(User) }
                     else
                       shared_recipients(scope_type: scope_type, company: company, location: location,
                                         email_cfg: email_cfg, sending_user: sending_user,
                                         affected_user: affected_user)
                     end
        to_notify = candidates.uniq(&:id).reject { |u| notified.include?(u.id) }
        next if entry && to_notify.empty?

        health[channel] = {
          'error'           => entry&.dig('error').presence || message.to_s.truncate(500),
          'at'              => entry&.dig('at').presence || Time.current.iso8601,
          'notifiedUserIds' => (notified + to_notify.map(&:id)).uniq
        }
        setting.update!(value: data.to_json)
      end

      to_notify.each do |user|
        notify_shared(user, scope_type, channel, company, location, email_cfg, message)
      end
      if to_notify.any?
        Rails.logger.warn(
          "[EmailConnectionHealth] #{scope_type} #{scope_id} #{channel} sender failing; " \
          "notified users #{to_notify.map(&:id).join(',')}"
        )
      end
      to_notify.any?
    rescue => e
      Rails.logger.error "[EmailConnectionHealth] Failed to flag #{scope_type} #{scope_id} sender: #{e.message}"
      false
    end

    # Clears one channel's marker (or all of them). Reads before locking so the
    # common case, a healthy sender, costs one select.
    def clear_shared!(scope_type:, scope_id:, channel: nil)
      setting = shared_setting(scope_type, scope_id)
      return false unless setting&.value.to_s.include?(HEALTH_KEY)

      cleared = false
      Setting.transaction do
        setting.lock!
        data = parse(setting.value)
        health = data.dig('email', HEALTH_KEY)
        next unless health.is_a?(Hash)
        next if channel && !health.key?(channel)

        channel ? health.delete(channel) : health.clear
        data['email'].delete(HEALTH_KEY) if health.empty?
        setting.update!(value: data.to_json)
        cleared = true
      end
      cleared
    rescue => e
      Rails.logger.error "[EmailConnectionHealth] Failed to clear #{scope_type} #{scope_id} sender: #{e.message}"
      false
    end

    private

    def message_for(error)
      error.respond_to?(:message) ? error.message : error.to_s
    end

    def own_mailbox?(user)
      user.respond_to?(:has_email_connection?) && user.has_email_connection?
    end

    def context_of(communicable)
      location = communicable.try(:location)
      company  = communicable.try(:company) || location.try(:company)
      [company, location]
    end

    def notification_context(notification)
      metadata = notification.metadata.is_a?(Hash) ? notification.metadata : {}
      company_id = metadata['broadcasting_company_id'] || metadata[:broadcasting_company_id] || notification.company_id
      location = notification.location_id.present? ? Location.find_by(id: notification.location_id) : nil
      [Company.find_by(id: company_id), location]
    end

    # The most specific scope whose email settings set one of `fields`.
    def sender_scope(company:, location:, fields:)
      candidates = []
      candidates << ['Location', location.id] if location.respond_to?(:id) && location.id
      candidates << ['Company', company.id] if company.respond_to?(:id) && company.id
      candidates << ['Platform', 0]

      candidates.find do |type, id|
        email = parse(shared_setting(type, id)&.value)['email']
        email.is_a?(Hash) && fields.any? { |f| email[f].present? }
      end
    end

    def shared_setting(scope_type, scope_id)
      scope = Setting.where(scope_type: scope_type, key: 'communications')
      if scope_type == 'Platform'
        # The platform row has been written with scope_id 0 and with nil.
        scope.where(scope_id: [0, nil]).order(Arel.sql('scope_id IS NULL'), :id).first
      else
        scope.find_by(scope_id: scope_id)
      end
    end

    def parse(value)
      data = value.is_a?(Hash) ? value : JSON.parse(value.to_s)
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end

    def sender_address(email_cfg)
      email_cfg['oauthEmail'].presence || FROM_FIELDS.map { |f| email_cfg[f].presence }.compact.first
    end

    def active_users
      User.where(deleted_at: nil, status: 'active')
    end

    def shared_recipients(scope_type:, company:, location:, email_cfg:, sending_user:, affected_user:)
      users = [sending_user, affected_user].select { |u| u.is_a?(User) }

      owner_email = sender_address(email_cfg).to_s.downcase
      if owner_email.present?
        owners = active_users.where('LOWER(email) = ?', owner_email)
        owners = owners.where(company_id: company.id) if company && scope_type != 'Platform'
        users.concat(owners.to_a)
      end

      case scope_type
      when 'Location'
        users.concat(location.location_admins.merge(active_users).to_a) if location
        users.concat(company_admins(company))
      when 'Company'
        users.concat(company_admins(company))
      when 'Platform'
        users.concat(active_users.where(role: %w[platform_admin super_admin]).to_a)
      end

      users.uniq(&:id)
    end

    # Prod roles are display names ("Company Administrator"), so the admin test
    # has to go through company_admin?, which also reads RBAC role assignments.
    def company_admins(company)
      return [] unless company

      active_users.where(company_id: company.id).select(&:company_admin?)
    end

    def internal_user(company, to_address)
      return nil unless company

      address = Array(to_address).join(',')[/[^\s<>,;"]+@[^\s<>,;"]+/]
      return nil unless address

      User.where(company_id: company.id, deleted_at: nil).find_by('LOWER(email) = ?', address.downcase)
    end

    def notify_shared(user, scope_type, channel, company, location, email_cfg, message)
      NotificationService.create(
        recipient: user,
        notification_type: :email_connection_broken,
        message: shared_message(scope_type, channel, company, location, email_cfg, message),
        action_url: shared_action_url(scope_type, location),
        company_id: company&.id,
        location_id: location&.id,
        # In-app and push only. Email would most likely leave through the very
        # sender that is broken.
        deliver_now: false
      )
    rescue => e
      Rails.logger.error "[EmailConnectionHealth] Notification failed for user #{user.id}: #{e.message}"
    end

    def shared_message(scope_type, channel, company, location, email_cfg, message)
      owner = case scope_type
              when 'Location' then "The #{location&.name || 'location'} location's"
              when 'Company'  then "#{company&.name || 'Your company'}'s"
              else 'The platform'
              end
      address = sender_address(email_cfg)
      detail = message.to_s.squish.truncate(160)

      if channel == 'system_mail'
        "Notification emails are failing. #{owner} From address#{" (#{address})" if address} " \
          "is being rejected: #{detail} Set a verified From address in the email settings."
      elsif reauth_error?(message)
        label = PROVIDER_LABELS[email_cfg['provider'].to_s] || 'email'
        "#{owner} shared #{label} mailbox#{" (#{address})" if address} has lost its connection, " \
          'so email sent through it is failing. An admin needs to reconnect it in the email settings.'
      else
        label = PROVIDER_LABELS[email_cfg['provider'].to_s] || 'email'
        "#{owner} shared #{label} sender#{" (#{address})" if address} is being rejected: #{detail} " \
          'Email sent through it will keep failing until it is fixed in the email settings.'
      end
    end

    def shared_action_url(scope_type, location)
      case scope_type
      when 'Location' then location ? "/locations/#{location.id}" : '/settings?tab=locations'
      when 'Company'  then '/settings?tab=communications'
      else '/admin/settings'
      end
    end
  end
end
