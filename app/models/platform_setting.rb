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

    def lot_map
      Setting.get('Platform', PLATFORM_SCOPE_ID, 'lot_map') || default_lot_map
    end

    def lot_map=(value)
      Setting.set('Platform', PLATFORM_SCOPE_ID, 'lot_map', value)
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

    def default_lot_map
      {
        enabled: ENV['LOT_MAP_ENABLED'] == 'true',
        maptiler: {
          api_key: ENV['MAPTILER_API_KEY'],
          default_style: ENV['MAPTILER_DEFAULT_STYLE'] || 'streets'
        }
      }
    end
  end
end
