# frozen_string_literal: true

module Ses
  # Applies an SES event notification (delivered / bounced / complained) to the records it
  # concerns.
  #
  # This is the only source of positive delivery receipt the platform has. OAuth Gmail and
  # Microsoft Graph sends report nothing back, so campaign_sends.delivered_at was never
  # written and every dashboard open rate divided by zero. Anything sent through SES now
  # stamps it.
  #
  # SNS delivers at least once, so every write here is guarded to be idempotent.
  class EventProcessor
    Result = Struct.new(:handled, :event_type, :send_id, :communication_id, keyword_init: true)

    # SES bounceType values. "Undetermined" is treated as soft: retrying a maybe-permanent
    # address is cheaper than suppressing a real customer on a guess.
    HARD_BOUNCE_TYPE = 'Permanent'

    def self.process(message)
      new(message).process
    end

    def initialize(message)
      @message = message.is_a?(String) ? JSON.parse(message) : message.to_h.deep_stringify_keys
    end

    def process
      return Result.new(handled: false) if event_type.blank?
      return Result.new(handled: false) if ses_message_id.blank?

      communication = Communication.find_by(external_id: ses_message_id)
      if communication.nil?
        Rails.logger.info("[Ses::EventProcessor] No communication for SES MessageId #{ses_message_id} (#{event_type})")
        return Result.new(handled: false, event_type: event_type)
      end

      send_record = CampaignSend.find_by(communication_id: communication.id)

      case event_type
      when 'Delivery'  then handle_delivery(communication, send_record)
      when 'Bounce'    then handle_bounce(communication, send_record)
      when 'Complaint' then handle_complaint(communication, send_record)
      else
        return Result.new(handled: false, event_type: event_type)
      end

      Result.new(
        handled: true,
        event_type: event_type,
        send_id: send_record&.id,
        communication_id: communication.id
      )
    rescue => e
      Rails.logger.error("[Ses::EventProcessor] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
      Result.new(handled: false, event_type: event_type)
    end

    private

    attr_reader :message

    def event_type
      # eventType is the configuration-set event-destination shape, notificationType the
      # older direct-SNS shape. SES uses one or the other depending on how it was wired.
      @event_type ||= message['eventType'].presence || message['notificationType'].presence
    end

    def ses_message_id
      @ses_message_id ||= message.dig('mail', 'messageId')
    end

    def handle_delivery(communication, send_record)
      ActiveRecord::Base.transaction do
        # delivered_at is the idempotency key for the whole handler: SNS redelivers, and
        # Communication#delivered? reads `status`, which SES never sets.
        if communication.delivered_at.nil?
          communication.update_column(:delivered_at, Time.current)
          communication.track_event('delivered', provider_data: message)
        end

        next if send_record.nil? || send_record.delivered_at.present?

        send_record.update_column(:delivered_at, Time.current)
        record_campaign_event(send_record, 'delivered', 'source' => 'ses_notification')
      end
    end

    def handle_bounce(communication, send_record)
      bounce = message['bounce'] || {}
      hard = bounce['bounceType'] == HARD_BOUNCE_TYPE
      payload = {
        'bounce_type' => hard ? 'hard' : 'soft',
        'ses_bounce_type' => bounce['bounceType'],
        'ses_bounce_subtype' => bounce['bounceSubType'],
        'diagnostic' => bounce.dig('bouncedRecipients', 0, 'diagnosticCode').to_s[0, 500],
        'source' => 'ses_notification'
      }

      ActiveRecord::Base.transaction do
        communication.track_event('bounced', provider_data: message)

        next if send_record.nil?
        next if send_record.bounced_at.present?

        send_record.update!(bounced_at: Time.current, bounce_type: hard ? 'hard' : 'soft')

        if hard
          suppress!(send_record, reason: 'bounce_hard')
          fail_enrollment!(send_record, reason: bounce['bounceSubType'].presence || 'ses hard bounce')
          flag_recipient_email_invalid(send_record)
        else
          count_soft_bounce(send_record, payload)
        end

        record_campaign_event(send_record, 'bounced_async', payload)
        fire_webhook(send_record, 'campaign.bounced', bounce_type: payload['bounce_type'])
      end
    end

    def handle_complaint(communication, send_record)
      complaint = message['complaint'] || {}
      payload = {
        'feedback_type' => complaint['complaintFeedbackType'],
        'source' => 'ses_notification'
      }

      ActiveRecord::Base.transaction do
        communication.track_event('spam_report', provider_data: message)

        next if send_record.nil?

        # A complaint is the strongest possible unsubscribe signal, and AWS suspends
        # accounts on complaint rate. Suppress unconditionally, even if this address has
        # already bounced.
        suppress!(send_record, reason: 'complaint')
        fail_enrollment!(send_record, reason: 'spam complaint', status: 'unsubscribed')
        record_campaign_event(send_record, 'complaint', payload)
        fire_webhook(send_record, 'campaign.complaint', feedback_type: complaint['complaintFeedbackType'])
      end
    end

    def suppress!(send_record, reason:)
      email = recipient_email(send_record)
      return if email.blank?

      CampaignSuppression.find_or_create_by(company_id: send_record.company_id, email_address: email) do |s|
        s.reason = reason
        s.source_campaign_id = send_record.campaign_id
        s.suppressed_at = Time.current
      end
    end

    def fail_enrollment!(send_record, reason:, status: 'bounced')
      enrollment = send_record.campaign_enrollment
      return if enrollment.nil?
      return if %w[bounced unsubscribed completed].include?(enrollment.status)

      attrs = { status: status, failure_reason: reason.to_s[0, 200] }
      attrs[:bounced_at] = Time.current if status == 'bounced' && enrollment.respond_to?(:bounced_at)
      enrollment.update!(attrs)
    end

    def count_soft_bounce(send_record, payload)
      enrollment = send_record.campaign_enrollment
      return if enrollment.nil?

      meta = (enrollment.metadata || {}).deep_stringify_keys
      meta['retry_count'] = meta['retry_count'].to_i + 1
      meta['last_soft_bounce_at'] = Time.current.iso8601
      meta['last_soft_bounce_subtype'] = payload['ses_bounce_subtype']

      if meta['retry_count'] >= 3
        enrollment.update!(status: 'failed', failure_reason: 'soft_bounce_exhausted_ses', metadata: meta)
      else
        enrollment.update!(metadata: meta)
      end
    end

    def flag_recipient_email_invalid(send_record)
      recipient = send_record.campaign_enrollment&.recipient
      return unless recipient.respond_to?(:email_invalid=)

      recipient.update_column(:email_invalid, true)
    rescue => e
      Rails.logger.warn("[Ses::EventProcessor] could not flag email_invalid: #{e.message}")
    end

    def recipient_email(send_record)
      send_record.campaign_enrollment&.email_address_snapshot.to_s.downcase.strip
    end

    def record_campaign_event(send_record, type, payload)
      CampaignEvent.create!(
        company_id: send_record.company_id,
        campaign_id: send_record.campaign_id,
        campaign_enrollment_id: send_record.campaign_enrollment_id,
        campaign_send_id: send_record.id,
        event_type: type,
        occurred_at: Time.current,
        payload: payload.deep_stringify_keys
      )
    end

    def fire_webhook(send_record, event, extra)
      return unless defined?(WebhookService)

      WebhookService.fire(
        company_id: send_record.company_id,
        event: event,
        payload: {
          campaign_id: send_record.campaign_id,
          enrollment_id: send_record.campaign_enrollment_id,
          send_id: send_record.id,
          source: 'ses_notification'
        }.merge(extra)
      )
    rescue => e
      Rails.logger.warn("[Ses::EventProcessor] webhook fire failed: #{e.message}")
    end
  end
end
