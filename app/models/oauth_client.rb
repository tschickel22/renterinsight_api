# frozen_string_literal: true

# An AI app that can ask a user to connect it to DealerTide: Claude, ChatGPT,
# Claude Code, an MCP inspector. Apps register themselves (dynamic client
# registration, or a Client ID Metadata Document URL used as client_id), so a
# row here grants nothing on its own. Access only exists once a user approves
# it on the consent screen, which creates an OauthGrant.
#
# All clients are public (no secret, token_endpoint_auth_method "none"); PKCE
# is what binds the code to the app that started the flow.
class OauthClient < ApplicationRecord
  has_many :oauth_grants, dependent: :destroy

  validates :client_id, presence: true, uniqueness: true
  validates :client_name, presence: true
  validates :registration_type, inclusion: { in: %w[dcr cimd] }
  validate :redirect_uris_allowed

  def redirect_uri_registered?(uri)
    redirect_uris.include?(uri.to_s) || loopback_match?(uri.to_s)
  end

  private

  # RFC 8252 section 7.3: a native app's loopback redirect may use any port,
  # so a registered http://127.0.0.1/callback also accepts :53682/callback.
  # localhost, 127.0.0.1 and [::1] are treated as the same machine, as
  # Claude's connector docs ask (Claude Code may register one and use another).
  def loopback_match?(uri)
    candidate = Oauth::RedirectPolicy.parse(uri)
    return false unless candidate && Oauth::RedirectPolicy.loopback?(candidate)

    redirect_uris.any? do |registered|
      reg = Oauth::RedirectPolicy.parse(registered)
      reg && Oauth::RedirectPolicy.loopback?(reg) && reg.path == candidate.path && reg.scheme == candidate.scheme
    end
  end

  def redirect_uris_allowed
    uris = Array(redirect_uris)
    errors.add(:redirect_uris, 'must list at least one redirect URI') if uris.empty?
    uris.each do |uri|
      errors.add(:redirect_uris, "#{uri} is not an allowed redirect") unless Oauth::RedirectPolicy.allowed?(uri)
    end
  end
end
