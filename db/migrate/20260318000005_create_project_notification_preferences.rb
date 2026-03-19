# frozen_string_literal: true

class CreateProjectNotificationPreferences < ActiveRecord::Migration[8.0]
  def change
    create_table :project_notification_preferences do |t|
      t.references :project, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true

      t.string :recipient_type, null: false
      t.bigint :recipient_id, null: false
      t.string :recipient_email
      t.string :recipient_phone

      t.boolean :notify_phase_started, default: true
      t.boolean :notify_phase_completed, default: true
      t.boolean :notify_task_assigned, default: true
      t.boolean :notify_task_completed, default: false
      t.boolean :notify_inspection_scheduled, default: true
      t.boolean :notify_inspection_passed, default: true
      t.boolean :notify_inspection_failed, default: true
      t.boolean :notify_milestone_reached, default: true
      t.boolean :notify_payment_due, default: true
      t.boolean :notify_daily_summary, default: false

      t.boolean :via_email, default: true
      t.boolean :via_sms, default: false

      t.boolean :is_active, default: true

      t.timestamps
    end

    add_index :project_notification_preferences,
              [:project_id, :recipient_type, :recipient_id],
              unique: true,
              name: 'idx_proj_notif_prefs_unique'
  end
end
