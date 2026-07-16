# Verifies a Cloudflare Turnstile response token against the siteverify endpoint.
# Returns true only if Cloudflare replies with success: true.
#
# Configure via ENV:
#   TURNSTILE_SITE_KEY   — public site key, safe to ship down to the browser
#   TURNSTILE_SECRET_KEY — server-side secret used to verify submitted tokens
#
# When TURNSTILE_SECRET_KEY is not set the verifier fails closed (returns false),
# so a misconfigured environment can never accidentally let unverified traffic
# through on a form flagged captcha_required.
class TurnstileVerifier
  VERIFY_URL = 'https://challenges.cloudflare.com/turnstile/v0/siteverify'.freeze

  def self.site_key
    ENV['TURNSTILE_SITE_KEY']
  end

  def self.configured?
    ENV['TURNSTILE_SECRET_KEY'].present?
  end

  def self.verify(token, remote_ip: nil)
    return false if token.blank?
    return false unless configured?

    body = { secret: ENV['TURNSTILE_SECRET_KEY'], response: token }
    body[:remoteip] = remote_ip if remote_ip.present?

    uri = URI(VERIFY_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 5

    req = Net::HTTP::Post.new(uri)
    req.set_form_data(body)
    res = http.request(req)

    parsed = JSON.parse(res.body) rescue {}
    parsed['success'] == true
  rescue => e
    Rails.logger.warn "[TurnstileVerifier] verification error: #{e.class}: #{e.message}"
    false
  end
end
