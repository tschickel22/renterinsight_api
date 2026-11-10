# frozen_string_literal: true

# Throttles the endpoints anyone on the internet can call without signing in:
# sign-in, password reset, magic links, MFA codes, and public form submits.
#
# Built on Rails' own `rate_limit`, keyed by request.remote_ip, which
# CloudflareClientIp has already set to the real visitor rather than the
# Cloudflare edge. Without that every visitor would share a handful of edge
# addresses and the limits would lock out real people.
#
# The counters live in a memory store of their own, not Rails.cache. Production
# Rails.cache is per instance anyway, and keeping these apart means a cache clear
# cannot reset them and a burst of attempts cannot evict real cache entries. The
# cost: each web instance counts separately, so with two instances the effective
# ceiling is up to twice the number written here. That still stops a bot; it is
# not meant to be exact.
#
# Limits are set for real offices: a dealership signs in a dozen people from one
# address every morning, and a trade show kiosk submits many forms from one
# tablet. Raise a limit before lowering it if a dealer reports a 429.
module AbuseRateLimit
  extend ActiveSupport::Concern

  STORE = ActiveSupport::Cache::MemoryStore.new(size: 32.megabytes)

  BY_IP = -> { request.remote_ip }
  BY_EMAIL = -> { "email:#{params[:email].to_s.downcase.strip.presence || request.remote_ip}" }

  class_methods do
    # abuse_limit to: 30, within: 5.minutes, only: :create, name: 'login-ip'
    def abuse_limit(to:, within:, name:, by: AbuseRateLimit::BY_IP, **options)
      rate_limit(
        to: to,
        within: within,
        by: by,
        name: name,
        store: AbuseRateLimit::STORE,
        with: -> { render_abuse_limited(name, within) },
        **options
      )
    end
  end

  private

  def render_abuse_limited(name, within)
    Rails.logger.warn(
      "[AbuseRateLimit] #{name} refused ip=#{request.remote_ip} " \
      "path=#{request.path} ua=#{request.user_agent.to_s[0, 120].inspect}"
    )
    response.set_header('Retry-After', within.to_i.to_s)
    render json: { success: false, error: 'Too many attempts. Please wait a few minutes and try again.' },
           status: :too_many_requests
  end
end
