# frozen_string_literal: true

# Platform-wide default settings that serve as the base for all companies and locations
class PlatformDefaults
  class << self
    def branding_settings
      {
        'primary_color' => '#3B82F6',
        'secondary_color' => '#10B981',
        'logo_url' => nil,
        'company_name' => 'RenterInsight'
      }
    end

    def communication_settings
      {
        'email_from_name' => 'RenterInsight',
        'email_from_address' => 'noreply@renterinsight.com',
        'sms_from_number' => nil,
        'enable_email' => true,
        'enable_sms' => false
      }
    end

    def operational_settings
      {
        'timezone' => 'America/New_York',
        'business_hours' => default_business_hours,
        'delivery_radius_miles' => 50,
        'allow_weekend_delivery' => false,
        'require_appointment' => false
      }
    end

    def integration_settings
      {
        'zoho' => {
          'enabled' => false
        },
        'quickbooks' => {
          'enabled' => false
        }
      }
    end

    private

    def default_business_hours
      {
        'monday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false },
        'tuesday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false },
        'wednesday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false },
        'thursday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false },
        'friday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false },
        'saturday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => true },
        'sunday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => true }
      }
    end
  end
end
