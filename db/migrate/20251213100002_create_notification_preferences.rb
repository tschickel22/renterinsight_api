class CreateNotificationPreferences < ActiveRecord::Migration[7.0]
  def change
    create_table :notification_preferences do |t|
      t.bigint :user_id, null: false
      
      # Notification type and category
      t.string :notification_type, null: false
      t.string :category, null: false
      
      # Channel preferences
      t.boolean :in_app_enabled, default: true, null: false
      t.boolean :email_enabled, default: false, null: false
      t.boolean :sms_enabled, default: false, null: false
      
      # Frequency settings
      t.string :frequency, default: 'immediate' # immediate, daily, weekly, disabled
      
      # Quiet hours
      t.boolean :respect_quiet_hours, default: false
      t.time :quiet_hours_start
      t.time :quiet_hours_end
      
      t.timestamps
    end
    
    # Indexes
    add_index :notification_preferences, [:user_id, :notification_type], unique: true, name: 'index_notification_prefs_on_user_and_type'
    add_index :notification_preferences, :category
  end
end
