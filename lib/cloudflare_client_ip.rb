# frozen_string_literal: true

require 'ipaddr'

# Every request reaches us through Render's Cloudflare edge, so ActionDispatch's own
# answer for request.remote_ip is that edge server, not the visitor. Login records,
# e-sign records and rate limits all read remote_ip. Cloudflare sets CF-Connecting-IP
# itself and refuses requests that try to supply it.
class CloudflareClientIp
  # What Cloudflare reports for a request made by a Worker (dealer sites run behind
  # Workers), which is not a visitor.
  WORKER_ADDRESS = '2a06:98c0:3600::103'

  def initialize(app)
    @app = app
  end

  def call(env)
    candidate = env['HTTP_CF_CONNECTING_IP'].to_s.strip
    env['action_dispatch.remote_ip'] = candidate if visitor?(candidate)
    @app.call(env)
  end

  private

  def visitor?(candidate)
    return false if candidate.empty? || candidate == WORKER_ADDRESS

    IPAddr.new(candidate)
    true
  rescue IPAddr::Error
    false
  end
end
