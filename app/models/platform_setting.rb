# frozen_string_literal: true

# Convenience wrapper for platform-wide settings
class PlatformSetting
  PLATFORM_SCOPE_ID = 0

  class << self
    def communications
      Setting.get('Platform', PLATFORM_SCOPE_ID, 'communications') || default_communications
    end

    def communications=(value)
      Setting.set('Platform', PLATFORM_SCOPE_ID, 'communications', value)
    end

    def notifications
      Setting.get('Platform', PLATFORM_SCOPE_ID, 'notifications') || default_notifications
    end

    def notifications=(value)
      Setting.set('Platform', PLATFORM_SCOPE_ID, 'notifications', value)
    end

    private

    def default_communications
      {
        email: {
          provider: ENV['EMAIL_PROVIDER'] || 'smtp',
          fromEmail: ENV['EMAIL_FROM'] || 'platform@renterinsight.com',
          fromName: ENV['EMAIL_FROM_NAME'] || 'RenterInsight Platform',
          isEnabled: ENV['EMAIL_ENABLED'] != 'false'
        },
        sms: {
          provider: ENV['SMS_PROVIDER'] || 'twilio',
          fromNumber: ENV['SMS_FROM_NUMBER'],
          isEnabled: ENV['SMS_ENABLED'] == 'true'
        }
      }
    end

    def default_notifications
      {
        email: { isEnabled: true, sendReminders: true },
        sms: { isEnabled: false, sendReminders: true },
        popup: { isEnabled: true, autoClose: true, autoCloseDelay: 5000 }
      }
    end
  end
end
