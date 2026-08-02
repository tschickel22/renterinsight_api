# frozen_string_literal: true

module Messaging
  # Per-mailbox sending rate limits.
  #
  # Every provider publishes a rate ceiling and enforces it by restricting the
  # account, not by queueing. Exchange Online allows 30 messages/minute; campaign 26
  # sent 225 in one minute and the mailbox was blocked outright ("550 5.1.8 Access
  # denied, bad outbound sender"). Defaults here sit well under each published
  # ceiling so a burst degrades into a delay instead of a restriction.
  #
  # Resolution order, most specific wins:
  #   1. per-connection override  (setting["connections"]["UserEmailConnection:35"])
  #   2. per-provider override    (setting["providers"]["oauth_outlook"])
  #   3. PROVIDER_DEFAULTS[provider]
  #   4. FALLBACK
  #
  # Overrides live in one Platform setting rather than columns on the three
  # *_email_connection models, so a single edit retunes every tenant on a
  # provider, and a single mailbox that needs to ramp back up after a
  # restriction can be pinned low by key without a migration.
  class SendRateLimits
    SETTING_KEY = 'send_rate_limits'
    PLATFORM_SCOPE_ID = 0

    PROVIDER_DEFAULTS = {
      # Exchange Online: 30/min published ceiling.
      'oauth_outlook' => { 'per_minute' => 10, 'per_hour' => 200, 'per_day' => 2_000 },
      # Google Workspace: 2,000/day published ceiling.
      'oauth_gmail' => { 'per_minute' => 10, 'per_hour' => 200, 'per_day' => 1_500 },
      'smtp' => { 'per_minute' => 10, 'per_hour' => 200, 'per_day' => 2_000 },
      'aws_ses' => { 'per_minute' => 50, 'per_hour' => 2_000, 'per_day' => 50_000 }
    }.freeze

    # Applied when the provider is unknown. Deliberately the most conservative
    # row: an unrecognised transport should crawl, not sprint.
    FALLBACK = { 'per_minute' => 10, 'per_hour' => 200, 'per_day' => 1_000 }.freeze

    KEYS = %w[per_minute per_hour per_day].freeze

    def self.for(connection_key:, provider: nil)
      new(connection_key: connection_key, provider: provider).limits
    end

    def initialize(connection_key:, provider: nil)
      @connection_key = connection_key.presence
      @provider = provider.presence || provider_from_key
    end

    def limits
      @limits ||= begin
        resolved = FALLBACK
                   .merge(PROVIDER_DEFAULTS.fetch(@provider.to_s, {}))
                   .merge(stringify(configured.dig('providers', @provider.to_s)))
                   .merge(stringify(configured.dig('connections', @connection_key)))
        resolved.slice(*KEYS).transform_values { |v| v.to_i }
      end
    end

    # Seconds between consecutive sends, taken as the wider of the per-minute
    # and per-hour rates so both are satisfied by construction.
    #
    # per_day is deliberately NOT folded in. It is a daily ceiling, not a rate:
    # smearing 2,000/day across 24 hours would space sends 43 seconds apart and
    # stretch a batch that should finish in an afternoon across a full day.
    # The ceiling is enforced by Messaging::ThrottleChecker, which stops sending
    # once the quota is spent rather than slowing everything down to reach it.
    def interval_seconds
      candidates = [
        seconds_per(limits['per_minute'], 60.0),
        seconds_per(limits['per_hour'], 3_600.0)
      ].compact
      candidates.empty? ? 0.0 : candidates.max
    end

    private

    def seconds_per(cap, window)
      return nil if cap.nil? || cap <= 0
      window / cap
    end

    # "UserEmailConnection:35" tells us which row to ask for its provider.
    # Falls back to nil (=> FALLBACK limits) if the row is gone.
    def provider_from_key
      return nil if @connection_key.blank?
      klass_name, id = @connection_key.split(':', 2)

      # A verified tenant sending domain is always SES. Without this it would fall through
      # to FALLBACK and crawl at mailbox speed, which is the opposite of why a tenant
      # verified a domain.
      return 'aws_ses' if klass_name == 'CompanyDomain'

      return nil unless %w[UserEmailConnection LocationEmailConnection CompanyEmailConnection].include?(klass_name)
      klass_name.constantize.where(id: id).pick(:provider)
    rescue StandardError => e
      Rails.logger.warn "[SendRateLimits] provider lookup failed for #{@connection_key}: #{e.message}"
      nil
    end

    def configured
      @configured ||= begin
        raw = Setting.get('Platform', PLATFORM_SCOPE_ID, SETTING_KEY)
        raw.is_a?(Hash) ? raw : {}
      rescue StandardError => e
        Rails.logger.warn "[SendRateLimits] setting read failed: #{e.message}"
        {}
      end
    end

    def stringify(hash)
      hash.is_a?(Hash) ? hash.transform_keys(&:to_s) : {}
    end
  end
end
