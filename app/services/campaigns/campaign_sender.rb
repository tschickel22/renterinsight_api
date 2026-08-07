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

    # Why this sender declined to send, when deliver_current_step returns false.
    #
    # Most of the reasons are recorded on the enrollment or the CampaignSend, but every one
    # of those writes is skipped for test sends, and the guards that fire before a
    # CampaignSend exists leave no record at all. That left the test-send endpoint with a
    # bare false and nothing to report but a guess, which is how "outside the send window"
    # reached an admin as "check email connection".
    attr_reader :last_skip_reason

    def initialize(enrollment:, base_url: nil)
      @enrollment = enrollment
      @campaign = enrollment.campaign
      @company = @campaign.company
      @last_skip_reason = nil
      # Must point to the Rails API server for tracked links, unsubscribe links, and pixel URLs
      @base_url = base_url || Messaging::TrackingUrl.base
    end

    def deliver_current_step
      step = current_step
      return mark_completed unless step

      return mark_failed('contact_value_missing') if contact_value.blank?
      return mark_unsubscribed if suppressed?

      # The send window protects the recipients of an automated campaign from being mailed at
      # 3am. A test send goes to the admin who just pressed the button, so there is nothing
      # to protect and applying it only stops them working. It was worse than a delay:
      # reschedule_to is a no-op for test sends, so a test outside the window was not
      # deferred, it silently failed, and every test after 6pm reported itself to the admin
      # as a broken email connection.
      unless test_send?
        window = Messaging::SendWindowCalculator.new(
          send_window: @campaign.send_window, channel: @campaign.channel,
          recipient: recipient, company: @company
        ).evaluate
        return reschedule_to(window, reason: 'outside_send_window') if window.is_a?(Time)
      end

      step_channel = step.effective_channel
      connection_key = nil
      if step_channel == 'email'
        # test_platform_send lets an admin dry-run an Owner-mode campaign
        # without binding to a real Lead/Contact/Account: the test routes
        # through platform SES so it doesn't need any specific owner's
        # OAuth connection to exist. Skips this preflight only for that path.
        unless test_platform_send?
          # Owner mode resolves per-recipient — pass the enrollment's
          # recipient so we look up THIS recipient's owner's connection,
          # not a global campaign-wide one.
          conn_preflight = @campaign.resolve_email_connection_for_step(recipient: recipient)
          return mark_failed('no_valid_email_connection') if conn_preflight.nil?
          connection_key = Campaign.connection_key_for(conn_preflight)
        end
      else
        return mark_failed('no_valid_sms_sender') if @campaign.resolve_sms_sender_for_step.nil?
      end

      # Runs AFTER connection resolution now. Rate limits are counted per mailbox,
      # so the check needs to know which mailbox this send would use; when it ran
      # first it could only see the campaign, which is exactly why two campaigns
      # sharing a mailbox could each spend a full daily budget against it.
      remember_connection_key(connection_key)
      throttle = Messaging::ThrottleChecker.new(campaign: @campaign, connection_key: connection_key).check
      return reschedule_to(throttle.retry_at, reason: 'rate_limited') if throttle.throttled?

      # Monthly volume ceiling, separate from the per-mailbox rate check above. Rate is a
      # deliverability limit; this is a billing limit.
      #
      # Over cap the enrollment is pushed to the start of next month rather than failed.
      # Failing it would permanently kill every queued recipient the moment a company hit
      # its allowance, and retrying in minutes would churn for weeks without ever
      # succeeding. Pushing to the reset matches what the cap notification tells the tenant:
      # automated sends are paused, not cancelled.
      if step_channel == 'email' && !test_send?
        begin
          EmailCapService.check!(company: @company, source: 'campaign')
        rescue EmailCapService::CapExceededError => e
          Rails.logger.warn "[CampaignSender] #{e.message} (campaign #{@campaign.id})"
          return reschedule_to(Time.current.next_month.beginning_of_month)
        end
      end

      send_record = CampaignSend.create!(
        company_id: @company.id, campaign_id: @campaign.id,
        campaign_step_id: step.id, campaign_enrollment_id: @enrollment.id,
        sending_connection_key: connection_key
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

    # True when the controller flagged this enrollment as an Owner-mode
    # test send that should bypass per-recipient owner resolution and go
    # out via platform SES instead. See CampaignsController#test_send.
    def test_platform_send?
      @enrollment.metadata.is_a?(Hash) && @enrollment.metadata['test_platform_send'].to_s == 'true'
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
      # test_platform_send skips per-recipient owner resolution and sends
      # via platform SES so an Owner-mode campaign can be smoke-tested
      # without any owner's OAuth connection being wired up. The rendered
      # content is unchanged so the test still reflects the real campaign.
      conn = test_platform_send? ? nil : @campaign.resolve_email_connection_for_step(recipient: recipient)
      rendered = Messaging::EmailRenderer.new(
        step: step, recipient: recipient, campaign: @campaign,
        campaign_send: send_record, company: @company, base_url: @base_url
      ).render

      return { success: false, error: 'inventory_empty_abort' } if rendered[:error] == 'inventory_empty_abort'

      inline_uploads        = Array(rendered[:inline_attachments])
      tracked_link_records  = Array(rendered[:tracked_link_records])
      attachment_metadata   = Array(rendered[:attachment_metadata])

      from_address = formatted_from_for(conn) || platform_test_from_address
      # Was hardcoded to mail.renterinsight.com behind ENV['INBOUND_EMAIL_DOMAIN'], a name
      # nothing else in the app sets or reads (the real variable is INBOUND_MAIL_DOMAIN),
      # so every campaign reply-to fell through to the literal regardless of configuration.
      # A DealerTide campaign then carried a Renter Insight reply address.
      reply_to = ReplyToAddressService.campaign_address(send_record, company: @company)

      provider_sym = if test_platform_send?
                       :aws_ses
                     else
                       case conn.try(:provider).to_s
                       when 'oauth_gmail'   then :oauth_google
                       when 'oauth_outlook' then :oauth_microsoft
                       # A verified tenant sending domain. Still the tenant's own identity
                       # and DKIM, not the shared platform one.
                       when 'aws_ses'       then :aws_ses
                       else :smtp
                       end
                     end

      metadata_hash = {
        campaign_id: @campaign.id,
        campaign_send_id: send_record.id,
        campaign_step_id: step.id,
        source: 'campaign',
        attachments: attachment_metadata.map { |a| { 'filename' => a['filename'], 'delivery_mode' => a['delivery_mode'] } }
      }

      result = CommunicationService.send_email(
        communicable: recipient,
        to: contact_value,
        from: from_address,
        subject: rendered[:subject],
        body: rendered[:html_body],
        reply_to: reply_to,
        provider: provider_sym,
        category: 'campaign',
        attachments: inline_uploads.presence,
        metadata: metadata_hash.deep_stringify_keys,
        skip_preference_check: true,
        sender_user_id: conn.try(:user_id),
        user: conn.try(:user)
      )

      if result.is_a?(Hash) && result[:success]
        comm = result[:communication]
        # No pixel injection here. CommunicationService injects it *before* the
        # provider reads the body, so it reaches the recipient. Re-injecting
        # afterwards only rewrote the stored copy, which made the DB look
        # instrumented while the delivered mail carried a different (dead) URL.
        comm.update_column(:campaign_send_id, send_record.id) if Communication.column_names.include?('campaign_send_id')

        tracked_link_records.each do |tl|
          tl.update_columns(communication_id: comm.id) rescue nil
        end

        { success: true, communication_id: comm.id }
      else
        err = result.is_a?(Hash) ? (result[:error] || 'send_failed') : 'send_failed'
        # Flag the mailbox this campaign actually resolved for this recipient,
        # not the owner's default. An owner can have more than one connected
        # account, and blaming the wrong one sends them to reconnect a mailbox
        # that was never involved.
        EmailConnectionHealth.flag!(conn, err)
        { success: false, error: err.to_s[0, 200] }
      end
    rescue => e
      Rails.logger.error "[CampaignSender#deliver_email] #{e.class}: #{e.message}"
      EmailConnectionHealth.flag!(conn, e)
      { success: false, error: e.message.to_s[0, 200] }
    ensure
      Array(inline_uploads).each do |u|
        tmp = u.respond_to?(:tempfile) ? u.tempfile : nil
        begin
          tmp&.close
          tmp&.unlink
        rescue StandardError
          nil
        end
      end
    end

    def deliver_sms(step, send_record)
      twilio_acct = @campaign.resolve_sms_sender_for_step
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
      conn.try(:email_address) || conn.try(:from_email_address) || conn.try(:email)
    end

    # From-address for test_platform_send. Uses the campaign's configured
    # display name (if any) wrapped around a platform-verified inbox. Falls
    # back to the brand kernel's From address so we always render a valid
    # RFC-5322 address even when the campaign has no display name set.
    def platform_test_from_address
      base = ENV['PLATFORM_TEST_FROM'].presence || Brand.from_email
      name = @campaign.try(:from_display_name).to_s.strip
      name.present? ? "#{name} <#{base}>" : base
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

    def reschedule_to(time, reason: 'rescheduled')
      @last_skip_reason = reason
      @enrollment.update!(next_send_at: time) unless test_send?
      false
    end

    # Persist the resolved mailbox on the enrollment so SendPacer can see what a
    # mailbox already has queued when allocating future slots. Matters most for
    # Owner-mode campaigns (the mailbox is only known per recipient) and for
    # enrollments created before pacing existed.
    def remember_connection_key(key)
      return if key.blank? || test_send?
      return if @enrollment.sending_connection_key == key
      @enrollment.update_column(:sending_connection_key, key)
    end

    def mark_failed(reason)
      @last_skip_reason = reason.to_s
      @enrollment.update!(status: 'failed', failure_reason: reason.to_s[0, 200]) unless test_send?
      CampaignEvent.create!(
        company_id: @company.id, campaign_id: @campaign.id, campaign_enrollment_id: @enrollment.id,
        event_type: 'failed', occurred_at: Time.current, payload: { reason: reason.to_s[0, 200] }
      ) unless test_send?
      false
    end

    def mark_unsubscribed
      @last_skip_reason = 'recipient_unsubscribed'
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
