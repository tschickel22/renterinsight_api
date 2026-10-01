# frozen_string_literal: true

# One user's approval for one AI app at one company: the "connected app" they
# see under Settings, Integrations, AI Apps. Every token and every tool call
# hangs off a grant, so revoking it cuts the app off on its next request.
#
# The company is fixed when the user approves. A grant never follows a user
# into another company and never carries impersonation.
class OauthGrant < ApplicationRecord
  SCOPES = %w[mcp:read mcp:write].freeze

  belongs_to :oauth_client
  belongs_to :user
  belongs_to :company
  has_many :oauth_tokens, dependent: :delete_all
  has_many :oauth_authorization_codes, dependent: :delete_all

  scope :active, -> { where(revoked_at: nil) }

  def self.normalize_scopes(raw)
    requested = raw.to_s.split(/[\s,]+/) & SCOPES
    requested = ['mcp:read'] if requested.empty?
    requested << 'mcp:read' if requested.include?('mcp:write') && !requested.include?('mcp:read')
    SCOPES & requested
  end

  def scope_list
    scopes.to_s.split
  end

  def write_allowed?
    scope_list.include?('mcp:write')
  end

  def active?
    revoked_at.nil?
  end

  def revoke!(by_user: nil)
    return if revoked_at

    transaction do
      update!(revoked_at: Time.current, revoked_by_user_id: by_user&.id)
      oauth_tokens.where(revoked_at: nil).update_all(revoked_at: Time.current)
    end
  end

  def touch_used!
    return if last_used_at && last_used_at > 5.minutes.ago

    update_column(:last_used_at, Time.current)
  end
end
