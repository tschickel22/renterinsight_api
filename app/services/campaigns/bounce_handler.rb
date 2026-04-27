module Campaigns
  class BounceHandler
    Result = Struct.new(:handled, :classification, :enrollment_id, :send_id, keyword_init: true)

    DSN_CONTENT_TYPE_PATTERNS = [
      /multipart\/report.*report-type\s*=\s*delivery-status/i,
      /message\/delivery-status/i
    ].freeze

    BOUNCE_FROM_PATTERNS = [
      /\bmailer-daemon\b/i,
      /\bpostmaster@/i,
      /\bbounces?@/i,
      /\bnoreply@/i,
      /\bno-reply@/i
    ].freeze

    BOUNCE_SUBJECT_PATTERNS = [
      /\bundeliverable\b/i,
      /\bdelivery (status|failed|failure|notification)\b/i,
      /\bfailure notice\b/i,
      /\breturned mail\b/i,
      /\bmail delivery failed\b/i,
      /\bcouldn'?t be delivered\b/i,
      /\baddress (rejected|not found)\b/i,
      /\bmailbox unavailable\b/i,
      /\buser unknown\b/i
    ].freeze

    HARD_BOUNCE_BODY_PATTERNS = [
      /\b550\b.*(no such user|user unknown|address rejected|mailbox not found|does not exist|recipient address rejected)\b/i,
      /\b5\.1\.\d\b/i,
      /\b5\.0\.0\b/i,
      /\baddress.*rejected\b/i,
      /\bno such user\b/i,
      /\buser unknown\b/i,
      /\bmailbox (not found|unavailable|does not exist)\b/i,
      /\bdomain (not found|unknown)\b/i,
      /\brecipient address rejected\b/i
    ].freeze

    SOFT_BOUNCE_BODY_PATTERNS = [
      /\b4\.\d\.\d\b/i,
      /\bquota exceeded\b/i,
      /\bover quota\b/i,
      /\bmailbox full\b/i,
      /\btry again\b/i,
      /\btemporarily\b/i,
      /\bcould not be delivered\b/i
    ].freeze

    OOO_HEADER_PATTERNS = [
      /auto-?submitted:\s*auto-replied/i,
      /x-autoreply/i, /x-autorespond/i,
      /precedence:\s*auto/i,
      /auto-?submitted:\s*auto-generated/i
    ].freeze

    OOO_SUBJECT_PATTERNS = [
      /out of office/i,
      /automatic reply/i,
      /auto[- ]reply/i,
      /vacation/i,
      /away from (the )?office/i,
      /out of the office/i,
      /currently away/i,
      /on (vacation|leave|holiday)/i
    ].freeze

    def self.process(token:, parsed_email:)
      return Result.new(handled: false) unless token.to_s.start_with?('campaign-')

      send_id = token.split('-', 2).last.to_i
      send = CampaignSend.find_by(id: send_id)
      return Result.new(handled: false) unless send

      classification = classify(parsed_email)

      case classification
      when :bounce_hard
        handle_hard_bounce(send, parsed_email)
        Result.new(handled: true, classification: classification, enrollment_id: send.campaign_enrollment_id, send_id: send.id)
      when :bounce_soft
        handle_soft_bounce(send, parsed_email)
        Result.new(handled: true, classification: classification, enrollment_id: send.campaign_enrollment_id, send_id: send.id)
      when :auto_reply
        handle_auto_reply(send, parsed_email)
        Result.new(handled: true, classification: classification, enrollment_id: send.campaign_enrollment_id, send_id: send.id)
      else
        Result.new(handled: false, classification: :real_reply)
      end
    rescue => e
      Rails.logger.error "[Campaigns::BounceHandler] #{e.class}: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      Result.new(handled: false)
    end

    def self.classify(parsed_email)
      headers = parsed_email[:headers].to_s
      from = parsed_email[:from].to_s
      subject = parsed_email[:subject].to_s
      body = parsed_email[:body_text].to_s
      content_type = parsed_email[:content_type].to_s

      return :auto_reply if OOO_HEADER_PATTERNS.any? { |p| headers.match?(p) }
      return :auto_reply if OOO_SUBJECT_PATTERNS.any? { |p| subject.match?(p) }

      is_dsn = DSN_CONTENT_TYPE_PATTERNS.any? { |p| content_type.match?(p) || headers.match?(p) }
      is_bounce_from = BOUNCE_FROM_PATTERNS.any? { |p| from.match?(p) }
      is_bounce_subject = BOUNCE_SUBJECT_PATTERNS.any? { |p| subject.match?(p) }

      if is_dsn || is_bounce_from || is_bounce_subject
        return :bounce_hard if HARD_BOUNCE_BODY_PATTERNS.any? { |p| body.match?(p) }
        return :bounce_soft if SOFT_BOUNCE_BODY_PATTERNS.any? { |p| body.match?(p) }
        return :bounce_hard if is_dsn || is_bounce_from
        return :bounce_soft
      end

      :real_reply
    end

    def self.handle_hard_bounce(send, parsed_email)
      ActiveRecord::Base.transaction do
        send.update!(bounced_at: Time.current, bounce_type: 'hard') if send.bounced_at.nil?

        recipient_email = send.campaign_enrollment&.email_address_snapshot.to_s.downcase.strip
        if recipient_email.present?
          CampaignSuppression.find_or_create_by(company_id: send.company_id, email_address: recipient_email) do |s|
            s.reason = 'bounce_hard'
            s.source_campaign_id = send.campaign_id
          end
        end

        if send.campaign_enrollment.present?
          enrollment = send.campaign_enrollment
          enrollment.update!(
            status: 'bounced',
            bounced_at: Time.current,
            failure_reason: parsed_email[:subject].to_s[0, 200].presence || 'async hard bounce'
          )

          recipient = enrollment.recipient
          if recipient.respond_to?(:email_invalid) && recipient.respond_to?(:email_invalid=)
            begin
              recipient.update_column(:email_invalid, true)
            rescue
            end
          end
        end

        CampaignEvent.create!(
          company_id: send.company_id,
          campaign_id: send.campaign_id,
          campaign_enrollment_id: send.campaign_enrollment_id,
          campaign_send_id: send.id,
          event_type: 'bounced_async',
          occurred_at: Time.current,
          payload: {
            'bounce_type' => 'hard',
            'subject' => parsed_email[:subject].to_s[0, 500],
            'from' => parsed_email[:from].to_s[0, 200],
            'source' => 'inbound_dsn'
          }
        )

        if defined?(WebhookService)
          WebhookService.fire(
            company_id: send.company_id,
            event: 'campaign.bounced',
            payload: {
              campaign_id: send.campaign_id,
              enrollment_id: send.campaign_enrollment_id,
              send_id: send.id,
              bounce_type: 'hard',
              source: 'async_dsn'
            }
          )
        end
      end
    end

    def self.handle_soft_bounce(send, parsed_email)
      ActiveRecord::Base.transaction do
        send.update!(bounced_at: Time.current, bounce_type: 'soft') if send.bounced_at.nil?

        if send.campaign_enrollment.present?
          enrollment = send.campaign_enrollment
          meta = (enrollment.metadata || {}).deep_stringify_keys
          meta['retry_count'] = (meta['retry_count'].to_i + 1)
          meta['last_soft_bounce_subject'] = parsed_email[:subject].to_s[0, 200]
          meta['last_soft_bounce_at'] = Time.current.iso8601

          if meta['retry_count'].to_i >= 3
            enrollment.update!(status: 'failed', failure_reason: 'soft_bounce_exhausted_async', metadata: meta)
          else
            enrollment.update!(metadata: meta)
          end
        end

        CampaignEvent.create!(
          company_id: send.company_id,
          campaign_id: send.campaign_id,
          campaign_enrollment_id: send.campaign_enrollment_id,
          campaign_send_id: send.id,
          event_type: 'bounced_async',
          occurred_at: Time.current,
          payload: {
            'bounce_type' => 'soft',
            'subject' => parsed_email[:subject].to_s[0, 500],
            'from' => parsed_email[:from].to_s[0, 200],
            'source' => 'inbound_dsn'
          }
        )
      end
    end

    def self.handle_auto_reply(send, parsed_email)
      CampaignEvent.create!(
        company_id: send.company_id,
        campaign_id: send.campaign_id,
        campaign_enrollment_id: send.campaign_enrollment_id,
        campaign_send_id: send.id,
        event_type: 'auto_reply_received',
        occurred_at: Time.current,
        payload: {
          'subject' => parsed_email[:subject].to_s[0, 500],
          'from' => parsed_email[:from].to_s[0, 200],
          'source' => 'inbound_ooo'
        }
      )
    end
  end
end
