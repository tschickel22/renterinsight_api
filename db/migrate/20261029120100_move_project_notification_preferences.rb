# frozen_string_literal: true

# E87: project, contractor and installer notifications get their own group in
# Notification Center. A preference row keeps the category it was created
# with, and the category switches update by that column, so move the existing
# rows too.
class MoveProjectNotificationPreferences < ActiveRecord::Migration[8.0]
  TYPES = %w[
    contractor_review_submitted contractor_review_approved contractor_review_revision
    contractor_review_rejected contractor_task_assigned project_phase_completed
    contractor_work_log_added contractor_invoice_submitted project_bid_submitted
    company_link project_link
  ].freeze

  def up
    execute <<~SQL
      UPDATE notification_preferences SET category = 'projects', updated_at = NOW()
      WHERE notification_type IN (#{TYPES.map { |t| connection.quote(t) }.join(', ')})
    SQL

    # These two only ever rang the bell, so a stored "email off" was never
    # anyone's choice: Notification Center made the row with the old default
    # the first time the page opened. Rows somebody saved since are left alone.
    execute <<~SQL
      UPDATE notification_preferences SET email_enabled = TRUE, sms_enabled = TRUE, updated_at = NOW()
      WHERE notification_type IN ('contractor_invoice_submitted', 'project_bid_submitted')
        AND updated_at <= created_at + INTERVAL '1 second'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE notification_preferences SET category = 'finance', updated_at = NOW()
      WHERE notification_type = 'contractor_invoice_submitted'
    SQL
    execute <<~SQL
      UPDATE notification_preferences SET category = 'service', updated_at = NOW()
      WHERE notification_type IN (#{(TYPES - ['contractor_invoice_submitted']).map { |t| connection.quote(t) }.join(', ')})
    SQL
  end
end
