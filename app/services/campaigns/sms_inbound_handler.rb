module Campaigns
  # Inbound SMS keyword handler for campaign-related responses.
  #
  # Called from Webhooks::TwilioController#sms_inbound BEFORE the existing
  # routing logic. Returns Result(handled:, reply_body:, event_type:).
  # When handled=true the caller sends the reply via the company's TwilioAccount
  # number (via TwilioSmsService.send_via_master with from_number set to the
  # company's number — the only permitted use of master credentials in
  # campaign-related code paths, for legally-required compliance auto-replies).
  class SmsInboundHandler
    STOP_KEYWORDS  = %w[stop unsubscribe cancel quit end opt-out optout].freeze
    HELP_KEYWORDS  = %w[help info].freeze
    START_KEYWORDS = %w[start unstop subscribe yes].freeze

    Result = Struct.new(:handled, :reply_body, :event_type, keyword_init: true)

    def self.process(from_phone:, body:, to_phone:)
      keyword = classify_keyword(body)
      return Result.new(handled: false) unless keyword

      normalized_phone = normalize_phone(from_phone)

      twilio_acct = TwilioAccount.where(phone_number: normalize_phone(to_phone), status: 'active').first
      return Result.new(handled: false) unless twilio_acct

      company_id = twilio_acct.company_id

      enrollment_exists = CampaignEnrollment
        .where(company_id: company_id, sms_phone_snapshot: normalized_phone)
        .exists?

      return Result.new(handled: false) unless enrollment_exists

      case keyword
      when :stop
        handle_stop(company_id, normalized_phone, twilio_acct)
      when :help
        handle_help(company_id, twilio_acct)
      when :start
        handle_start(company_id, normalized_phone, twilio_acct)
      end
    end

    def self.classify_keyword(body)
      return nil if body.blank?
      first = body.to_s.strip.downcase.split(/[\s,;:.!?]+/, 2).first
      return :stop  if STOP_KEYWORDS.include?(first)
      return :help  if HELP_KEYWORDS.include?(first)
      return :start if START_KEYWORDS.include?(first)
      nil
    end

    def self.handle_stop(company_id, phone, _twilio_acct)
      ActiveRecord::Base.transaction do
        CampaignSuppression.find_or_create_by(company_id: company_id, phone_number: phone) do |s|
          s.reason = 'sms_stop'
        end

        affected = CampaignEnrollment
          .where(company_id: company_id, sms_phone_snapshot: phone)
          .where(status: %w[pending active paused])

        affected.find_each do |e|
          e.update!(status: 'unsubscribed', unsubscribed_at: Time.current)
          CampaignEvent.create!(
            company_id: company_id, campaign_id: e.campaign_id,
            campaign_enrollment_id: e.id,
            event_type: 'sms_stop', occurred_at: Time.current,
            payload: { phone: phone, source: 'inbound_sms' }
          )
          if defined?(WebhookService)
            WebhookService.fire(
              company_id: company_id, event: 'campaign.unsubscribed',
              payload: { campaign_id: e.campaign_id, enrollment_id: e.id, phone: phone, reason: 'sms_stop' }
            )
          end
        end
      end

      Result.new(
        handled: true,
        reply_body: "You're unsubscribed and won't receive further messages. Reply START to opt back in.",
        event_type: 'sms_stop'
      )
    end

    def self.handle_help(company_id, _twilio_acct)
      company = Company.find(company_id)
      contact_info = [company.name, company.phone, company.email].compact.reject(&:blank?).join(' | ')
      contact_info = company.name if contact_info.blank?
      Result.new(
        handled: true,
        reply_body: "Msg & data rates may apply. #{contact_info}. Reply STOP to unsubscribe.",
        event_type: 'sms_help'
      )
    end

    def self.handle_start(company_id, phone, _twilio_acct)
      ActiveRecord::Base.transaction do
        CampaignSuppression.where(company_id: company_id, phone_number: phone, reason: 'sms_stop').destroy_all
        # We do NOT auto-resume past enrollments. User starts fresh on next campaign.
      end

      Result.new(
        handled: true,
        reply_body: "You're opted back in. Reply STOP at any time to unsubscribe.",
        event_type: 'sms_start'
      )
    end

    def self.normalize_phone(phone)
      digits = phone.to_s.gsub(/\D/, '')
      return phone if digits.blank?
      if digits.length == 10
        "+1#{digits}"
      elsif digits.length == 11 && digits.start_with?('1')
        "+#{digits}"
      else
        "+#{digits}"
      end
    end
  end
end
