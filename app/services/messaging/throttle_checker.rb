# frozen_string_literal: true

module Messaging
  # Runtime backstop for send pacing.
  #
  # Messaging::SendPacer does the real work by spreading next_send_at at
  # scheduling time. This catches what pacing cannot: two campaigns enrolling
  # into the same mailbox at once, concurrent advance_to_next_step calls, and
  # enrollments scheduled before pacing existed.
  #
  # The windows are measured per MAILBOX. Measuring per campaign (the previous
  # behaviour, and the whole of it) meant two campaigns on one mailbox each got
  # their own throttle_per_day budget, so the mailbox absorbed both.
  class ThrottleChecker
    Result = Struct.new(:status, :reason, :retry_at, keyword_init: true) do
      def throttled?
        status == :throttled
      end

      def ok?
        status == :ok
      end
    end

    # [limit key, window length in seconds]
    WINDOWS = [
      ['per_minute', 60],
      ['per_hour', 3_600],
      ['per_day', 86_400]
    ].freeze

    def initialize(campaign:, connection_key: nil, now: Time.current)
      @campaign = campaign
      @connection_key = connection_key.presence
      @now = now
    end

    def check
      if @connection_key
        WINDOWS.each do |limit_key, seconds|
          cap = limits[limit_key].to_i
          next unless cap.positive?

          scope = mailbox_sends_since(@now - seconds.seconds)
          next if scope.count < cap

          return throttled("mailbox_#{limit_key}", scope.minimum(:sent_at), seconds)
        end
      end

      cap = (@campaign.throttle_per_day || 500).to_i
      if cap.positive?
        scope = CampaignSend.where(campaign_id: @campaign.id).where('sent_at >= ?', @now - 24.hours)
        return throttled('campaign_per_day', scope.minimum(:sent_at), 86_400) if scope.count >= cap
      end

      if @campaign.sms_channel?
        begin
          SmsCapService.check!(company: @campaign.company, source: 'campaign')
        rescue SmsCapService::CapExceededError
          return throttled('sms_cap', nil, 3_600)
        end
      end

      # The tenant-wide ceiling, sitting above every campaign they are running.
      # Checked last: it is the most expensive of these and the least often hit.
      tenant_cap = Messaging::TenantSendCap.check(
        company: @campaign.company,
        channel: @campaign.sms_channel? ? 'sms' : 'email',
        now: @now
      )
      if tenant_cap.exceeded?
        Rails.logger.info(
          "[ThrottleChecker] company #{@campaign.company_id} is at its daily #{tenant_cap.channel} cap " \
          "(#{tenant_cap.sent_today}/#{tenant_cap.cap})"
        )
        return throttled("tenant_daily_#{tenant_cap.channel}", oldest_tenant_send_in_window, 86_400)
      end

      Result.new(status: :ok)
    end

    private

    # Retry when the oldest send in the tenant's rolling day ages out, the same
    # way the mailbox windows do, rather than parking everything for a flat 24h.
    def oldest_tenant_send_in_window
      CampaignSend.where(company_id: @campaign.company_id)
                  .where('sent_at >= ?', @now - 24.hours)
                  .minimum(:sent_at)
    end

    def limits
      @limits ||= Messaging::SendRateLimits.for(connection_key: @connection_key)
    end

    def mailbox_sends_since(time)
      CampaignSend.where(sending_connection_key: @connection_key).where('sent_at >= ?', time)
    end

    # These are rolling windows, so capacity frees the moment the oldest send in
    # the window ages out of it. Retrying then is both the earliest correct time
    # and far more accurate than the flat 1-hour backoff this replaces, which
    # turned a 6-second per-minute trip into an hour of dead time.
    def throttled(reason, oldest_in_window, window_seconds)
      base = oldest_in_window ? oldest_in_window + window_seconds.seconds : @now + window_seconds.seconds
      base = @now + 5.seconds if base <= @now
      Result.new(status: :throttled, reason: reason, retry_at: base + jitter(window_seconds))
    end

    # Without jitter every enrollment throttled in the same window retries at the
    # same instant and the burst simply repeats one window later.
    def jitter(window_seconds)
      rand(0..[(window_seconds * 0.1).round, 5].max).seconds
    end
  end
end
