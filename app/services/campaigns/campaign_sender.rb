module Campaigns
  class CampaignSender
    class SendError < StandardError; end

    HARD_BOUNCE_PATTERNS = [
      /address.*rejected/i, /no such user/i, /user unknown/i,
      /mailbox unavailable/i, /recipient address rejected/i,
      /domain not found/i, /does not exist/i, /no such mailbox/i
    ].freeze
    SOFT_BOUNCE_PATTERNS = [
      /rate.?limit/i, /temporarily/i, /try again/i, /too many requests/i,
      /quota exceeded/i, /timeout/i, /timed out/i
    ].freeze

    SMS_HARD_TWILIO_CODES = %w[21610 30005 30007 21614 21408].freeze
    SMS_SOFT_TWILIO_CODES = %w[30008 20429].freeze

    def initialize(enrollment:, base_url: nil)
      @enrollment = enrollment
      @campaign = enrollment.campaign
      @company = @campaign.company
      @base_url = base_url || ENV['CAMPAIGN_BASE_URL'].presence || 'https://app.renterinsight.com'
    end

    def deliver_current_step
      step = current_step
      return mark_completed unless step

      return mark_failed('contact_value_missing') if contact_value.blank?
      return mark_unsubscribed if suppressed?

      window = Messaging::SendWindowCalculator.new(
        send_window: @campaign.send_window, channel: @campaign.channel,
        recipient: recipient, company: @company
      ).evaluate
      return reschedule_to(window) if window.is_a?(Time)

      throttle = Messaging::ThrottleChecker.new(campaign: @campaign).check
      return reschedule_to(1.hour.from_now) if throttle == :throttled

      step_channel = step.effective_channel
      if step_channel == 'email'
        return mark_failed('no_valid_email_connection') if @campaign.resolve_email_connection.nil?
      else
        return mark_failed('no_valid_sms_sender') if @campaign.resolve_sms_sender.nil?
      end

      send_record = CampaignSend.create!(
        company_id: @company.id, campaign_id: @campaign.id,
        campaign_step_id: step.id, campaign_enrollment_id: @enrollment.id
      )

      result = step_channel == 'email' ? deliver_email(step, send_record) : deliver_sms(step, send_record)

      if result[:success]
        send_record.update!(sent_at: Time.current, communication_id: result[:communication_id])
        advance_unless_test
        true
      else
        send_record.update!(metadata: send_record.metadata.merge('error' => result[:error]))
        handle_failure(result, send_record)
        false
      end
    end

    private

    def test_send?
      @enrollment.metadata.is_a?(Hash) && @enrollment.metadata['test_send'].to_s == 'true'
    end

    def advance_unless_test
      return if test_send?
      @enrollment.advance_to_next_step
    end

    def current_step
      @campaign.campaign_steps.active.ordered.offset(@enrollment.current_step_index).first
    end

    def recipient
      @enrollment.recipient
    end

    def contact_value
      step = current_step
      if step&.effective_channel == 'sms'
        @enrollment.sms_phone_snapshot
      else
        @enrollment.email_address_snapshot
      end
    end

    def suppressed?
      CampaignSuppression.suppressed?(@company.id, contact_value)
    end

    def deliver_email(step, send_record)
      conn = @campaign.resolve_email_connection
      rendered = Messaging::EmailRenderer.new(
        step: step, recipient: recipient, campaign: @campaign,
        campaign_send: send_record, company: @company, base_url: @base_url
      ).render

      return { success: false, error: 'inventory_empty_abort' } if rendered[:error] == 'inventory_empty_abort'

      from_address = formatted_from_for(conn)
      reply_to = "reply+campaign-#{send_record.id}@#{ENV['INBOUND_EMAIL_DOMAIN'].presence || 'mail.renterinsight.com'}"

      provider_sym = case conn.try(:provider).to_s
                     when 'oauth_gmail'   then :oauth_google
                     when 'oauth_outlook' then :oauth_microsoft
                     else :smtp
                     end

      result = CommunicationService.send_email(
        communicable: recipient,
        to: contact_value,
        from: from_address,
        subject: rendered[:subject],
        body: rendered[:html_body],
        reply_to: reply_to,
        provider: provider_sym,
        category: 'campaign',
        metadata: {
          campaign_id: @campaign.id,
          campaign_send_id: send_record.id,
          campaign_step_id: step.id,
          source: 'campaign'
        },
        skip_preference_check: true,
        sender_user_id: conn.try(:user_id),
        user: conn.try(:user)
      )

      if result.is_a?(Hash) && result[:success]
        comm = result[:communication]
        final_html = Messaging::PixelInjector.inject(rendered[:html_body], communication_id: comm.id, base_url: @base_url)
        comm.update_column(:body, final_html) if final_html != rendered[:html_body]
        comm.update_column(:campaign_send_id, send_record.id) if Communication.column_names.include?('campaign_send_id')
        { success: true, communication_id: comm.id }
      else
        err = result.is_a?(Hash) ? (result[:error] || 'send_failed') : 'send_failed'
        { success: false, error: err.to_s[0, 200] }
      end
    rescue => e
      Rails.logger.error "[CampaignSender#deliver_email] #{e.class}: #{e.message}"
      { success: false, error: e.message.to_s[0, 200] }
    end

    def deliver_sms(step, send_record)
      twilio_acct = @campaign.resolve_sms_sender
      return { success: false, error: 'no_valid_sms_sender' } unless twilio_acct

      rendered = Messaging::SmsRenderer.new(
        step: step, recipient: recipient, campaign: @campaign,
        campaign_send: send_record, company: @company, base_url: @base_url
      ).render

      sid, token = TwilioSmsService.master_credentials
      msid = TwilioSmsService.master_messaging_service_sid

      twilio_result = TwilioSmsService.send(
        to: contact_value,
        body: rendered[:body],
        from_number: twilio_acct.phone_number,
        account_sid: sid,
        auth_token: token,
        messaging_service_sid: msid
      )

      if twilio_result[:success]
        comm = Communication.create!(
          communicable: recipient, company_id: @company.id,
          channel: 'sms', direction: 'outbound',
          provider: 'twilio', status: 'sent',
          from_address: twilio_acct.phone_number, to_address: contact_value,
          body: rendered[:body], sent_at: Time.current,
          external_id: twilio_result[:message_sid],
          metadata: { 'campaign_id' => @campaign.id, 'campaign_send_id' => send_record.id, 'source' => 'campaign' }
        )
        comm.update_column(:campaign_send_id, send_record.id) if Communication.column_names.include?('campaign_send_id')

        SmsUsageLog.log!(company: @company, direction: 'outbound', source: 'campaign', communication_id: comm.id)

        { success: true, communication_id: comm.id }
      else
        { success: false, error: twilio_result[:error] || 'twilio_send_failed', twilio_code: twilio_result[:twilio_code] }
      end
    rescue => e
      Rails.logger.error "[CampaignSender#deliver_sms] #{e.class}: #{e.message}"
      { success: false, error: e.message.to_s[0, 200] }
    end

    def formatted_from_for(conn)
      return nil unless conn
      if conn.respond_to?(:formatted_from_address)
        conn.formatted_from_address
      else
        addr = conn.try(:from_email_address) || conn.try(:email_address) || conn.try(:email)
        name = conn.try(:from_display_name) || conn.try(:display_name)
        name.present? ? %("#{name}" <#{addr}>) : addr
      end
    end

    def handle_failure(result, send_record)
      err = result[:error].to_s
      step_channel = send_record.campaign_step&.effective_channel || @campaign.channel
      if step_channel == 'email'
        if HARD_BOUNCE_PATTERNS.any? { |p| err.match?(p) }
          handle_hard_email_bounce(send_record, err)
        elsif SOFT_BOUNCE_PATTERNS.any? { |p| err.match?(p) }
          handle_soft_bounce(send_record, err)
        else
          mark_failed(err[0, 200])
        end
      else
        code = result[:twilio_code].to_s
        if SMS_HARD_TWILIO_CODES.include?(code)
          handle_hard_sms_bounce(send_record, code, err)
        elsif SMS_SOFT_TWILIO_CODES.include?(code)
          handle_soft_bounce(send_record, err)
        else
          mark_failed(err[0, 200])
        end
      end
    end

    def handle_hard_email_bounce(send_record, err)
      send_record.update!(bounced_at: Time.current, bounce_type: 'hard')
      CampaignSuppression.find_or_create_by(company_id: @company.id, email_address: contact_value.to_s.downcase.strip) do |s|
        s.reason = 'bounce_hard'
        s.source_campaign_id = @campaign.id
      end
      if recipient.respond_to?(:email_invalid) && recipient.respond_to?(:email_invalid=)
        begin
          recipient.update_column(:email_invalid, true)
        rescue
        end
      end
      @enrollment.update!(status: 'bounced', bounced_at: Time.current, failure_reason: err[0, 200])
      WebhookService.fire(company_id: @company.id, event: 'campaign.bounced', payload: {
        campaign_id: @campaign.id, enrollment_id: @enrollment.id, send_id: send_record.id,
        bounce_type: 'hard', error: err[0, 200]
      }) if defined?(WebhookService)
    end

    def handle_hard_sms_bounce(send_record, code, err)
      send_record.update!(bounced_at: Time.current, bounce_type: 'hard')
      if code == '21610' # STOP
        CampaignSuppression.find_or_create_by(company_id: @company.id, phone_number: CampaignSuppression.normalize_phone_static(contact_value)) do |s|
          s.reason = 'sms_stop'
          s.source_campaign_id = @campaign.id
        end
        @enrollment.update!(status: 'unsubscribed', unsubscribed_at: Time.current, failure_reason: "twilio_#{code}")
      else
        CampaignSuppression.find_or_create_by(company_id: @company.id, phone_number: CampaignSuppression.normalize_phone_static(contact_value)) do |s|
          s.reason = 'bounce_hard'
          s.source_campaign_id = @campaign.id
        end
        @enrollment.update!(status: 'bounced', bounced_at: Time.current, failure_reason: "twilio_#{code}")
      end
      WebhookService.fire(company_id: @company.id, event: 'campaign.bounced', payload: {
        campaign_id: @campaign.id, enrollment_id: @enrollment.id, send_id: send_record.id,
        bounce_type: 'hard', twilio_code: code, error: err[0, 200]
      }) if defined?(WebhookService)
    end

    def handle_soft_bounce(send_record, err)
      meta = (@enrollment.metadata || {}).dup
      meta['retry_count'] = (meta['retry_count'].to_i + 1)
      meta['last_soft_error'] = err[0, 200]
      send_record.update!(bounce_type: 'soft', bounced_at: Time.current, metadata: send_record.metadata.merge('soft_error' => err[0, 200]))
      if meta['retry_count'].to_i >= 3
        @enrollment.update!(status: 'failed', failure_reason: "soft_bounce_exhausted: #{err[0, 100]}", metadata: meta)
      else
        @enrollment.update!(next_send_at: 1.hour.from_now, metadata: meta)
      end
    end

    def reschedule_to(time)
      @enrollment.update!(next_send_at: time) unless test_send?
      false
    end

    def mark_failed(reason)
      @enrollment.update!(status: 'failed', failure_reason: reason.to_s[0, 200]) unless test_send?
      CampaignEvent.create!(
        company_id: @company.id, campaign_id: @campaign.id, campaign_enrollment_id: @enrollment.id,
        event_type: 'failed', occurred_at: Time.current, payload: { reason: reason.to_s[0, 200] }
      ) unless test_send?
      false
    end

    def mark_unsubscribed
      @enrollment.update!(status: 'unsubscribed', unsubscribed_at: Time.current) unless test_send?
      false
    end

    def mark_completed
      return true if test_send?
      @enrollment.update!(status: 'completed', last_sent_at: Time.current) unless @enrollment.status == 'completed'
      true
    end
  end
end
