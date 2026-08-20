# frozen_string_literal: true

# A revocable, long-lived credential that a phone keeps in its Keychain behind
# Face ID or a fingerprint.
#
# The flow is: sign in normally once (password, and MFA if the company requires
# it), mint one of these, hand the raw token to the device to store behind
# biometrics. Every later launch is a biometric prompt and an exchange for a
# normal access token, so the password is never typed on a phone again and is
# never stored on one either.
#
# Sliding expiry rather than token rotation. Rotation is marginally stronger,
# but it means a failed Keychain write after the old token is spent locks the
# user out of their own phone, and on a device this is the wrong trade. The
# defence that matters here is revocation, which rotation does not provide.
class DeviceSession < ApplicationRecord
  LIFETIME = 90.days
  # A token unused for this long is a phone someone stopped carrying.
  IDLE_LIMIT = 30.days

  # Staff, customers and contractors all sign in on the same app and all forget
  # passwords, so the owner is polymorphic exactly as PushSubscription's is.
  belongs_to :owner, polymorphic: true

  # Rails records a polymorphic type as the BASE class, so a contractor is
  # stored as 'Vendor': Contractor is a subclass of Vendor with a default scope,
  # not a table of its own. Listing 'Contractor' here would reject every
  # contractor enrolment, which is exactly what it did first time round.
  OWNER_TYPES = %w[User BuyerPortalAccess Vendor].freeze

  validates :owner_type, inclusion: { in: OWNER_TYPES }

  scope :active, -> { where(revoked_at: nil).where('expires_at > ?', Time.current) }
  scope :for_device, ->(player_id) { where(player_id: player_id) if player_id.present? }
  scope :for_owner, lambda { |owner|
    where(owner_type: owner.class.base_class.name, owner_id: owner.id)
  }

  # Returns [record, raw_token]. The raw token is shown exactly once, here, and
  # is not recoverable afterwards.
  def self.issue!(owner:, device_label: nil, platform: nil, app_version: nil, player_id: nil)
    raw = SecureRandom.urlsafe_base64(32)

    # One biometric session per device, so re-enabling replaces rather than
    # accumulating rows that would each stay valid for 90 days.
    if player_id.present?
      for_owner(owner).where(player_id: player_id).active.to_a.each do |existing|
        existing.revoke!('replaced')
      end
    end

    record = create!(
      owner: owner,
      company_id: owner.try(:company_id),
      token_digest: digest(raw),
      device_label: device_label.presence&.truncate(80),
      platform: platform,
      app_version: app_version,
      player_id: player_id,
      expires_at: LIFETIME.from_now
    )

    [record, raw]
  end

  # Finds a usable session for a raw token, or nil. Never raises on a bad token:
  # a wrong value and an expired one are the same answer to the caller.
  def self.authenticate(raw_token)
    return nil if raw_token.blank?

    session = active.find_by(token_digest: digest(raw_token))
    return nil if session.blank?
    return nil if session.idle_too_long?

    session
  end

  def self.digest(raw_token)
    Digest::SHA256.hexdigest(raw_token.to_s)
  end

  # Revokes every biometric session an owner has. Called when a password
  # changes, and when a contractor is deactivated: whoever no longer knows the
  # password, or no longer works here, should not keep a phone that bypasses it.
  def self.revoke_all_for(owner, reason = 'password_changed')
    return 0 if owner.blank?

    for_owner(owner).active.to_a.each { |session| session.revoke!(reason) }.size
  end

  # Which app this session unlocks. Derived rather than stored: owner_type
  # already says it, and 'Vendor' means nothing to a phone.
  def audience
    case owner_type
    when 'User'              then 'staff'
    when 'BuyerPortalAccess' then 'portal'
    when 'Vendor'            then 'contractor'
    end
  end

  # What the exchange endpoint checks before minting a session. Each owner type
  # can be switched off in its own way, and none of them should keep working.
  def owner_usable?
    return false if owner.blank?

    case owner
    when ::User               then !(owner.inactive? || owner.suspended?)
    when ::BuyerPortalAccess  then owner.portal_enabled != false
    when ::Vendor             then contractor_usable?(owner)
    else false
    end
  rescue StandardError
    false
  end

  def idle_too_long?
    reference = last_used_at || created_at
    reference.present? && reference < IDLE_LIMIT.ago
  end

  def active?
    revoked_at.nil? && expires_at.present? && expires_at > Time.current && !idle_too_long?
  end

  # Sliding expiry: a phone in daily use should never be asked for a password
  # again, while one left in a drawer ages out on its own.
  def touch_use!
    update_columns(
      last_used_at: Time.current,
      use_count: use_count + 1,
      expires_at: LIFETIME.from_now,
      updated_at: Time.current
    )
  end

  def revoke!(reason = 'revoked')
    return true if revoked_at.present?

    update_columns(revoked_at: Time.current, revoked_reason: reason, updated_at: Time.current)
  end

  # Only contractors sign into a portal; a supplier row shares the table but has
  # no login, so it must never be able to unlock anything.
  def contractor_usable?(vendor)
    vendor.vendor_type == 'contractor' && vendor.status == 'active' && !vendor.is_deleted
  end

  def as_json_for_client(options = {})
    {
      id: id,
      device_label: device_label,
      platform: platform,
      app_version: app_version,
      last_used_at: last_used_at,
      created_at: created_at,
      expires_at: expires_at
    }.merge(options)
  end
end
