# frozen_string_literal: true

module Messaging
  # A ceiling on how much CAMPAIGN traffic one tenant can put through our
  # infrastructure in a day.
  #
  # Campaign#throttle_per_day is per campaign, so a tenant running four
  # campaigns at 500 sends 2,000 a day and nothing anywhere notices. Every
  # tenant shares one AWS account for email and one Twilio account for SMS, and
  # both providers judge on ACCOUNT-wide bounce, complaint and spam rates. One
  # dealer working a bought list degrades delivery for every other tenant and
  # can get the shared account reviewed or paused. This is the ceiling above the
  # per-campaign throttle that makes that impossible without anyone noticing.
  #
  # Two things it deliberately does not do:
  #
  #   It never touches transactional traffic. Password resets, quote emails,
  #   portal invites, one-off replies and rep-initiated texts are triggered by a
  #   person waiting on them, and are trivial in volume. Only campaign sends
  #   count, because campaigns are the reputation risk.
  #
  #   It does not cap a tenant sending on their OWN provider account. A dealer
  #   who brought their own Twilio credentials is spending their own reputation,
  #   and it is not our place to ration it. The cap applies when the account is
  #   ours: the platform Twilio, or a number we provisioned for them.
  class TenantSendCap
    Result = Struct.new(:status, :sent_today, :cap, :channel, keyword_init: true) do
      def exceeded? = status == :exceeded
      def ok? = status == :ok
    end

    # Applied when a tenant has no explicit cap. High enough not to interrupt a
    # normal dealer's day, low enough that a runaway list is stopped long before
    # AWS or Twilio notices it.
    DEFAULT_EMAIL_CAP = 500
    DEFAULT_SMS_CAP = 500

    def self.check(company:, channel:, now: Time.current)
      new(company: company, channel: channel, now: now).check
    end

    # Whether this channel is rationed for this tenant at all. False for SMS on
    # a tenant's own Twilio credentials, which we do not ration. Exposed so the
    # admin screen can say "not capped, they are on their own Twilio" rather
    # than showing a limit that will never apply.
    def self.applies_to?(company:, channel:)
      new(company: company, channel: channel).capped_channel?
    end

    def initialize(company:, channel:, now: Time.current)
      @company = company
      @channel = channel.to_s
      @now = now
    end

    def check
      return ok(nil) if @company.nil?
      return ok(nil) unless capped_channel?

      cap = configured_cap
      # A cap of zero or less means unlimited, matching how sms_monthly_limit
      # already reads, so the two settings do not mean opposite things.
      return ok(cap) unless cap.positive?

      sent = sent_today
      return Result.new(status: :exceeded, sent_today: sent, cap: cap, channel: @channel) if sent >= cap

      Result.new(status: :ok, sent_today: sent, cap: cap, channel: @channel)
    end

    # SMS is only capped while the tenant sends through our Twilio account.
    # Email is always ours: campaign email goes through the platform AWS account
    # whether or not the tenant verified their own sending domain, because a
    # verified domain changes the DKIM signature, not whose account it is.
    def capped_channel?
      return false if @company.nil?
      return true if @channel == 'email'
      return false unless @channel == 'sms'

      platform_owned_sms?
    end

    private

    def ok(cap)
      Result.new(status: :ok, sent_today: nil, cap: cap, channel: @channel)
    end

    # 'dedicated' is a number WE bought on the master Twilio account for this
    # tenant, so it is still our account and still our reputation.
    # 'platform' normally means the shared platform credentials, but a tenant
    # can override them with their own SID in company settings, and once they
    # do, the traffic is not on our account and we do not ration it.
    def platform_owned_sms?
      mode = @company.try(:sms_provisioning_mode).presence || 'platform'
      return false if mode == 'disabled'
      return true if mode == 'dedicated'

      !tenant_supplied_twilio_credentials?
    end

    # The key is 'communications', matching CommunicationSettingsService. A
    # company row carrying its own twilioAccountSid is a tenant sending on their
    # own Twilio, which the platform waterfall honours over our credentials.
    def tenant_supplied_twilio_credentials?
      setting = Setting.find_by(key: 'communications', scope_type: 'Company', scope_id: @company.id)
      value = setting&.value
      value = JSON.parse(value) if value.is_a?(String)
      return false unless value.is_a?(Hash)

      sms = value['sms'] || value[:sms] || {}
      (sms['twilioAccountSid'] || sms[:twilioAccountSid]).present?
    rescue StandardError => e
      # Unreadable settings must not silently exempt a tenant from the cap.
      Rails.logger.warn("[TenantSendCap] could not read SMS settings for company #{@company.id}: #{e.message}")
      false
    end

    def configured_cap
      explicit = @channel == 'sms' ? @company.try(:daily_campaign_sms_cap) : @company.try(:daily_campaign_email_cap)
      return explicit.to_i unless explicit.nil?

      @channel == 'sms' ? DEFAULT_SMS_CAP : DEFAULT_EMAIL_CAP
    end

    # Counted on a rolling 24 hours rather than since midnight, so a tenant
    # cannot spend tomorrow's budget at 23:59 and today's again at 00:01. It
    # also sidesteps having to pick a timezone for a company that spans two.
    def sent_today
      CampaignSend
        .joins(:campaign_step)
        .where(company_id: @company.id, campaign_steps: { channel: @channel })
        .where('campaign_sends.sent_at >= ?', @now - 24.hours)
        .count
    end
  end
end
