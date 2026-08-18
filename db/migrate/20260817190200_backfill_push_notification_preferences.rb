class BackfillPushNotificationPreferences < ActiveRecord::Migration[8.0]
  # Types that ship with push on. NotificationPreference::DEFAULT_SETTINGS only
  # applies when a preference row is first created, and every existing user
  # already has a full set of rows, so without this backfill the new column
  # stays false for everyone and the defaults never take effect.
  #
  # Deliberately a literal snapshot rather than a reference to the model
  # constant: this is a one-time correction to rows as they stood today, and it
  # must not silently re-run differently if those defaults are later retuned.
  PUSH_ON_BY_DEFAULT = %w[
    lead_assigned
    task_assigned
    task_overdue
    activity_reminder
    service_ticket_assigned
    quote_accepted
    deal_won
    payment_failed
    mention_received
    approval_required
    sms_reply_received
    email_reply_received
    system_alert
    contractor_task_assigned
  ].freeze

  def up
    execute <<~SQL.squish
      UPDATE notification_preferences
         SET push_enabled = TRUE,
             updated_at = NOW()
       WHERE notification_type IN (#{PUSH_ON_BY_DEFAULT.map { |t| connection.quote(t) }.join(', ')})
         AND push_enabled = FALSE
    SQL
  end

  def down
    execute 'UPDATE notification_preferences SET push_enabled = FALSE'
  end
end
