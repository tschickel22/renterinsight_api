# frozen_string_literal: true

module InboundEmail
  # Notifies the right person when a reply to a tracked email comes in.
  #
  # Recipient resolution (the key behavior): the person who SENT the original email
  # should get the reply — even if they don't own the record. We read
  # metadata['sender_user_id'] (stamped by CommunicationService "for reply forwarding")
  # from the originating outbound communication, falling back to the most recent outbound
  # to that entity, then the entity owner, then any active company user.
  #
  # Fan-out matches the existing reply-tracking notifications: in-app bell, email
  # (with Reply-To = the replier so the rep can respond straight from their inbox),
  # SMS, and a real-time ActionCable toast. Used by both the standard reply-tracking
  # path and Campaigns::ReplyHandler so all reply types behave identically.
  class ReplyNotifier
    def self.notify(entity:, communication:, outbound_communication: nil)
      new(entity: entity, communication: communication, outbound_communication: outbound_communication).notify
    end

    def initialize(entity:, communication:, outbound_communication: nil)
      @entity = entity
      @communication = communication
      @outbound_communication = outbound_communication
    end

    def notify
      return unless @entity && @communication
      user = recipient_user
      return unless user

      create_in_app_notification(user)
      send_email_notification(user)
      send_sms_notification(user)
      broadcast_toast(user)
    rescue => e
      Rails.logger.error "[ReplyNotifier] Failed: #{e.class}: #{e.message}"
      nil
    end

    private

    # sender of the original email → most-recent outbound sender → owner → any active user
    def recipient_user
      sender_from(@outbound_communication) ||
        latest_outbound_sender ||
        owner_fallback
    end

    def sender_from(outbound)
      return nil unless outbound.is_a?(Communication)
      uid = sender_user_id_for(outbound)
      uid.present? ? User.find_by(id: uid.to_i) : nil
    end

    # Walk recent outbounds to this entity (no jsonb SQL operators — robust to however
    # metadata is serialized) and return the first recorded sender.
    def latest_outbound_sender
      Communication
        .where(communicable_type: @entity.class.name, communicable_id: @entity.id, direction: 'outbound')
        .order(created_at: :desc).limit(25)
        .each do |c|
          uid = sender_user_id_for(c)
          return User.find_by(id: uid.to_i) if uid.present?
        end
      nil
    end

    # Extract sender_user_id from metadata whether it's a Hash, a JSON string, or a
    # Ruby-inspect string (metadata serialization has varied historically).
    def sender_user_id_for(comm)
      m = comm.metadata
      if m.is_a?(Hash)
        m['sender_user_id'] || m[:sender_user_id]
      elsif m.is_a?(String) && m.present?
        parsed = (JSON.parse(m) rescue nil)
        if parsed.is_a?(Hash)
          parsed['sender_user_id']
        else
          md = m.match(/sender_user_id["']?\s*(?:=>|:)\s*["']?(\d+)/)
          md && md[1]
        end
      end
    end

    def owner_fallback
      owner = case @entity
              when Lead, Account then @entity.try(:owner)
              when Contact       then @entity.try(:owner) || @entity.try(:account)&.try(:owner)
              else                    @entity.try(:owner)
              end
      owner || company&.users&.where(status: 'active')&.first
    end

    def company
      @company ||= @entity.try(:company)
    end

    def entity_name
      if @entity.respond_to?(:first_name)
        [@entity.first_name, @entity.last_name].compact.join(' ').strip.presence || @entity.try(:email)
      else
        @entity.try(:name) || @entity.try(:email) || 'Unknown'
      end
    end

    def entity_type_slug
      @entity.class.name.downcase
    end

    def entity_link
      "/crm/#{entity_type_slug}s/#{@entity.id}?tab=communications"
    end

    def preview
      strip(@communication.body)&.truncate(200)
    end

    def notification_settings(user)
      user.respond_to?(:notification_settings) ? (user.notification_settings || {}) : {}
    end

    def create_in_app_notification(user)
      return if notification_settings(user)['email_reply_in_app'] == false
      return if company.nil?
      Notification.create!(
        recipient: user, company_id: company.id,
        notification_type: 'email_reply_received',
        category: 'communications', priority: 'high',
        title: "Reply from #{entity_name}",
        message: "#{@communication.subject}: #{preview}".truncate(255),
        action_url: entity_link,
        metadata: {
          communication_id: @communication.id,
          entity_type: entity_type_slug, entity_id: @entity.id,
          from_address: @communication.from_address
        }
      )
    rescue => e
      Rails.logger.error "[ReplyNotifier] in-app notification failed: #{e.message}"
    end

    def send_email_notification(user)
      return if notification_settings(user)['email_reply_email'] == false
      return if user.email.blank?
      NotificationMailer.email_reply(
        user: user,
        entity_name: entity_name,
        entity_type: entity_type_slug,
        from_address: @communication.from_address,
        subject: @communication.subject,
        preview: preview,
        link: entity_link,
        reply_to_address: @communication.from_address # the replier — rep can respond directly
      ).deliver_later
    rescue => e
      Rails.logger.error "[ReplyNotifier] email notification failed: #{e.message}"
    end

    def send_sms_notification(user)
      return if notification_settings(user)['email_reply_sms'] == false
      return if user.try(:phone).blank?
      SmsService.new(company: company).send_sms(
        to: user.phone,
        body: "📧 Reply from #{entity_name}: #{@communication.subject}"
      )
    rescue => e
      Rails.logger.error "[ReplyNotifier] SMS notification failed: #{e.message}"
    end

    def broadcast_toast(user)
      ActionCable.server.broadcast(
        "user_notifications_#{user.id}",
        {
          type: 'email_reply',
          communication: { id: @communication.id, from: @communication.from_address,
                           subject: @communication.subject, preview: strip(@communication.body)&.truncate(100) },
          entity: { type: entity_type_slug, id: @entity.id, name: entity_name },
          timestamp: Time.current.iso8601
        }
      )
    rescue => e
      Rails.logger.error "[ReplyNotifier] toast broadcast failed: #{e.message}"
    end

    def strip(html)
      return nil if html.blank?
      text = ActionView::Base.full_sanitizer.sanitize(html.to_s)
      text.to_s.gsub('&nbsp;', ' ').gsub('&amp;', '&').gsub('&lt;', '<').gsub('&gt;', '>')
          .gsub('&quot;', '"').gsub('&#39;', "'").gsub('&apos;', "'").gsub(/\s+/, ' ').strip
    end
  end
end
