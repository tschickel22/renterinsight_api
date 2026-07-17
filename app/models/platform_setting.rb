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

    def general
      persisted = Setting.get('Platform', PLATFORM_SCOPE_ID, 'general')
      return default_general if persisted.blank?
      default_general.merge(persisted.symbolize_keys)
    end

    def general=(value)
      Setting.set('Platform', PLATFORM_SCOPE_ID, 'general', value)
    end

    def branding
      Setting.get('Platform', PLATFORM_SCOPE_ID, 'branding') || default_branding
    end

    def branding=(value)
      Setting.set('Platform', PLATFORM_SCOPE_ID, 'branding', value)
    end

    # Global master switch for guided tours. When true, no tours are served to
    # end users (regardless of each tour's individual is_active flag) and the
    # admin Tours tab is hidden. Individual tour states are left untouched so
    # toggling this back off restores exactly the prior configuration.
    def tours_paused?
      Setting.get('Platform', PLATFORM_SCOPE_ID, 'tours_paused') == true
    end

    def tours_paused=(value)
      Setting.set('Platform', PLATFORM_SCOPE_ID, 'tours_paused', value == true)
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

    def default_general
      {
        platformName: ENV['PLATFORM_NAME'] || 'RenterInsight',
        supportEmail: ENV['SUPPORT_EMAIL'] || 'support@renterinsight.com',
        salesEmail: ENV['SALES_EMAIL'] || 'sales@renterinsight.com',
        fromEmail: ENV['MAILER_FROM'] || ENV['DEFAULT_FROM_EMAIL'] || 'noreply@renterinsight.com',
        fromName: ENV['EMAIL_FROM_NAME'] || ENV['PLATFORM_NAME'] || 'RenterInsight',
        websiteUrl: ENV['PLATFORM_WEBSITE_URL'] || 'https://renterinsight.com',
        appUrl: ENV['APP_URL'] || ENV['FRONTEND_URL'] || 'https://app.renterinsight.com',
        privacyUrl: ENV['PLATFORM_PRIVACY_URL'] || 'https://www.renterinsight.com/privacy-policy/',
        termsUrl: ENV['PLATFORM_TERMS_URL'] || 'https://www.renterinsight.com/terms-of-use/',
        subdomainRoot: ENV['PLATFORM_SUBDOMAIN_ROOT'] || 'renterinsight.com',
        maintenanceMode: false,
        maintenanceMessage: 'We are currently performing scheduled maintenance. Please check back soon.'
      }
    end

    def default_branding
      {
        logo: nil,
        primaryColor: '#3b82f6',
        secondaryColor: '#8b5cf6',
        fontFamily: 'Inter',
        sideMenuColor: nil,
        portalName: ENV['PORTAL_NAME'] || 'Customer Portal',
        portalLogo: nil
      }
    end
  end
end
