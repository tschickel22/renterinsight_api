# frozen_string_literal: true

# Single-use, ten minute authorization code. Stored as a digest; the plaintext
# only ever travels in the redirect back to the AI app.
class OauthAuthorizationCode < ApplicationRecord
  TTL = 10.minutes

  belongs_to :oauth_grant

  def self.digest(code)
    Digest::SHA256.hexdigest(code.to_s)
  end

  # Returns [record, plaintext].
  def self.issue!(grant:, redirect_uri:, code_challenge:, scopes:)
    code = SecureRandom.urlsafe_base64(32)
    record = create!(
      oauth_grant: grant,
      code_digest: digest(code),
      redirect_uri: redirect_uri,
      code_challenge: code_challenge,
      scopes: Array(scopes).join(' '),
      expires_at: TTL.from_now,
      created_at: Time.current
    )
    [record, code]
  end

  def expired?
    expires_at <= Time.current
  end

  # RFC 7636 S256: BASE64URL(SHA256(code_verifier)) == code_challenge.
  def verifier_matches?(verifier)
    return false unless verifier.is_a?(String) && verifier.match?(/\A[A-Za-z0-9\-._~]{43,128}\z/)

    computed = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    ActiveSupport::SecurityUtils.secure_compare(computed, code_challenge)
  end
end
