class AddNotificationSettingsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :notification_settings, :jsonb, default: {
      activity_reminders: {
        enabled: true,
        channels: {
          bell: true,
          popup: true,
          email: false,
          sms: false
        }
      },
      lead_reminders: {
        enabled: true,
        channels: {
          bell: true,
          popup: true,
          email: false,
          sms: false
        }
      },
      contact_reminders: {
        enabled: true,
        channels: {
          bell: true,
          popup: true,
          email: false,
          sms: false
        }
      },
      account_reminders: {
        enabled: true,
        channels: {
          bell: true,
          popup: true,
          email: false,
          sms: false
        }
      }
    }
    
    add_index :users, :notification_settings, using: :gin
  end
end
