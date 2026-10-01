# frozen_string_literal: true

# Access and refresh tokens. Opaque random strings, stored as SHA-256 digests
# (the MCP server and the authorization server are the same app, so there is
# no need for a self-describing JWT). Access tokens live an hour; refresh
# tokens rotate on every use, and presenting one that was already used revokes
# the whole grant (OAuth 2.1 section 4.3.1 refresh token reuse detection).
class OauthToken < ApplicationRecord
  ACCESS_TTL = 1.hour
  REFRESH_TTL = 30.days
  ACCESS_PREFIX = 'dta_'
  REFRESH_PREFIX = 'dtr_'

  belongs_to :oauth_grant

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  # Returns { access_token:, refresh_token:, expires_in:, scope: }.
  def self.issue_pair!(grant:, scopes:)
    scope_str = Array(scopes).join(' ')
    access = "#{ACCESS_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    refresh = "#{REFRESH_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    now = Time.current
    insert_all!([
      { oauth_grant_id: grant.id, kind: 'access', token_digest: digest(access), scopes: scope_str,
        expires_at: now + ACCESS_TTL, created_at: now },
      { oauth_grant_id: grant.id, kind: 'refresh', token_digest: digest(refresh), scopes: scope_str,
        expires_at: now + REFRESH_TTL, created_at: now }
    ])
    { access_token: access, refresh_token: refresh, expires_in: ACCESS_TTL.to_i, scope: scope_str }
  end

  def self.find_by_plaintext(token, kind:)
    return nil if token.blank?

    find_by(token_digest: digest(token), kind: kind)
  end

  def usable?
    revoked_at.nil? && expires_at > Time.current && oauth_grant.active?
  end

  def scope_list
    scopes.to_s.split
  end
end
