# frozen_string_literal: true

# One row per device that has registered for push through the Natively native
# shell. Natively hands the web app a OneSignal player id; the app posts it here
# so the server can target the device later.
#
# Sends go to the `external_id` alias, not the player id, so one API call
# reaches every device a person has signed in on. Player ids are still stored
# because they are what OneSignal names in an error response, which is how a
# dead device gets pruned.
class PushSubscription < ApplicationRecord
  APPS = %w[staff portal].freeze
  PLATFORMS = %w[ios android web].freeze

  # A device that fails this many times in a row is almost certainly uninstalled.
  MAX_FAILURES = 5

  belongs_to :owner, polymorphic: true
  belongs_to :company, optional: true

  validates :player_id, presence: true, uniqueness: true
  validates :app, inclusion: { in: APPS }
  validates :platform, inclusion: { in: PLATFORMS }, allow_blank: true

  scope :active, -> { where(revoked_at: nil, permission_granted: true) }
  scope :for_app, ->(app) { where(app: app) }

  before_validation :set_external_id, on: :create

  # The alias the app tells OneSignal to associate with the device, and the one
  # the server pushes to. Kept in one place so the two sides cannot drift.
  def self.external_id_for(owner)
    case owner
    when User               then "staff:#{owner.id}"
    when BuyerPortalAccess  then "portal:#{owner.id}"
    else "#{owner.class.name.underscore}:#{owner.id}"
    end
  end

  def self.app_for(owner)
    owner.is_a?(BuyerPortalAccess) ? 'portal' : 'staff'
  end

  # Register or refresh a device. Called on every app launch, so it must be
  # idempotent and must move a player id that has changed hands (a shared
  # tablet signed into a different account) rather than 422 on the unique index.
  def self.register!(owner:, player_id:, **attrs)
    subscription = find_or_initialize_by(player_id: player_id)

    subscription.assign_attributes(
      attrs.slice(:platform, :device_model, :app_version, :natively_version).compact
    )
    subscription.owner = owner
    subscription.company_id = owner.try(:company_id)
    subscription.app = app_for(owner)
    subscription.external_id = external_id_for(owner)
    subscription.permission_granted = attrs.fetch(:permission_granted, true) != false
    subscription.last_seen_at = Time.current
    subscription.revoked_at = nil
    subscription.failure_count = 0
    subscription.last_error = nil
    subscription.save!

    subscription
  end

  def revoke!(reason = nil)
    update!(revoked_at: Time.current, last_error: reason)
  end

  def record_success!
    update_columns(last_success_at: Time.current, failure_count: 0, last_error: nil, updated_at: Time.current)
  end

  # A failure is only fatal after MAX_FAILURES. A single 4xx can be a transient
  # OneSignal state, and revoking on the first one silently unsubscribes people.
  def record_failure!(error)
    count = failure_count + 1
    attrs = { failure_count: count, last_error: error.to_s.truncate(250), updated_at: Time.current }
    attrs[:revoked_at] = Time.current if count >= MAX_FAILURES
    update_columns(attrs)
  end

  def as_json_for_client
    {
      id: id,
      app: app,
      platform: platform,
      device_model: device_model,
      permission_granted: permission_granted,
      last_seen_at: last_seen_at,
      created_at: created_at
    }
  end

  private

  def set_external_id
    self.external_id ||= self.class.external_id_for(owner) if owner.present?
  end
end
