class AddPushChannelToNotifications < ActiveRecord::Migration[8.0]
  def change
    # Per-type opt in for staff. Defaults to false here; the real per-type
    # defaults live in NotificationPreference::DEFAULT_SETTINGS and are applied
    # when a preference row is first created.
    add_column :notification_preferences, :push_enabled, :boolean, null: false, default: false

    # Delivery record, matching the existing email_sent / sms_sent columns.
    add_column :notifications, :push_sent, :boolean, default: false
    add_column :notifications, :push_sent_at, :datetime

    # Customer portal users get every key portal event, but they can still turn
    # push off without losing email/SMS.
    add_column :buyer_portal_accesses, :push_opt_in, :boolean, default: true
  end
end
