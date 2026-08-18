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

    # Mobile push (OneSignal, delivered through the Natively native shell).
    # Two OneSignal apps because Natively ships two separate builds: the staff
    # DMS app and the customer portal app. Deep-merged so setting one app's
    # credentials in Platform Admin does not blank the other's ENV defaults.
    def push
      persisted = Setting.get('Platform', PLATFORM_SCOPE_ID, 'push')
      return default_push if persisted.blank?

      persisted = persisted.deep_symbolize_keys
      default_push.merge(persisted) do |_key, default_value, persisted_value|
        default_value.is_a?(Hash) && persisted_value.is_a?(Hash) ? default_value.merge(persisted_value.compact) : persisted_value
      end
    end

    def push=(value)
      Setting.set('Platform', PLATFORM_SCOPE_ID, 'push', value)
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

    # Exposed publicly so callers that need the raw brand-kernel defaults
    # (e.g. the platform-settings controller's reset-to-defaults path) can
    # read them without reaching for `send(:default_general)`.
    def default_general
      {
        # The brand kernel's root default. Every `|| 'RenterInsight'` fallback
        # scattered through the app inherits from here, and Brand.current.name
        # resolves through it, so this is the one literal that decides what an
        # environment without a Platform settings row calls itself.
        platformName: ENV['PLATFORM_NAME'] || 'DealerTide',
        supportEmail: ENV['SUPPORT_EMAIL'] || 'support@dealertide.com',
        salesEmail: ENV['SALES_EMAIL'] || 'sales@dealertide.com',
        fromEmail: ENV['MAILER_FROM'] || ENV['DEFAULT_FROM_EMAIL'] || 'noreply@dealertide.com',
        fromName: ENV['EMAIL_FROM_NAME'] || ENV['PLATFORM_NAME'] || 'DealerTide',
        websiteUrl: ENV['PLATFORM_WEBSITE_URL'] || 'https://dealertide.com',
        # Last-resort only. app.renterinsight.com now resolves to a stale ELB,
        # so an unset APP_URL/FRONTEND_URL used to send users to a dead host.
        appUrl: ENV['APP_URL'] || ENV['FRONTEND_URL'] || 'https://app.dealertide.com',
        privacyUrl: ENV['PLATFORM_PRIVACY_URL'] || 'https://www.dealertide.com/privacy-policy/',
        termsUrl: ENV['PLATFORM_TERMS_URL'] || 'https://www.dealertide.com/terms-of-use/',
        subdomainRoot: ENV['PLATFORM_SUBDOMAIN_ROOT'] || 'dealertide.com',
        # Where TENANT SITES are served, which is deliberately not the platform's
        # own domain.
        #
        # Serving dealer sites off *.dealertide.com needs a wildcard record on
        # the apex zone, and dealertide.com is at GoDaddy with individually
        # created records: app resolves, everything else does not, so every
        # generated subdomain URL pointed at a host that does not exist.
        # mydealertide.com is a separate zone on Cloudflare precisely so a
        # wildcard can exist there without touching the marketing domain.
        #
        # Kept apart from subdomainRoot because that value also derives the
        # inbound mail domain and the domain-verification TXT prefix dealers
        # have already published. Moving site hosting must not silently move
        # either of those.
        siteHostRoot: ENV['PLATFORM_SITE_HOST_ROOT'] || 'mydealertide.com',
        maintenanceMode: false,
        maintenanceMessage: 'We are currently performing scheduled maintenance. Please check back soon.'
      }
    end

    private

    def default_communications
      {
        email: {
          provider: ENV['EMAIL_PROVIDER'] || 'smtp',
          # Defer to the brand kernel's defaults rather than carrying a second
          # sender literal that drifts from default_general.
          fromEmail: ENV['EMAIL_FROM'] || default_general[:fromEmail],
          fromName: ENV['EMAIL_FROM_NAME'] || default_general[:fromName],
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

    # One Natively build serves everyone: the login decides whether you land in
    # the DMS or the customer portal, so in practice there is ONE OneSignal app
    # and both audiences resolve to the same credentials via ONESIGNAL_APP_ID /
    # ONESIGNAL_API_KEY.
    #
    # The staff and portal keys stay separate here anyway, because the two
    # audiences are targeted by different external-id namespaces (staff:<id> vs
    # portal:<id>) and because shipping a second build later must not require a
    # code change. The per-audience vars simply win when they are set.
    def default_push
      shared_app_id  = ENV['ONESIGNAL_APP_ID'].presence
      shared_api_key = ENV['ONESIGNAL_API_KEY'].presence

      {
        provider: 'onesignal',
        isEnabled: ENV['PUSH_ENABLED'] != 'false',
        staff: {
          appId: ENV['ONESIGNAL_STAFF_APP_ID'].presence || shared_app_id,
          apiKey: ENV['ONESIGNAL_STAFF_API_KEY'].presence || shared_api_key
        },
        portal: {
          appId: ENV['ONESIGNAL_PORTAL_APP_ID'].presence || shared_app_id,
          apiKey: ENV['ONESIGNAL_PORTAL_API_KEY'].presence || shared_api_key
        }
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
