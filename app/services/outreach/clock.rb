# frozen_string_literal: true

module Outreach
  # When a message may go out (backlog E105): weekdays in business hours where
  # the lead is. Their state decides the time zone; without one, the company's.
  module Clock
    FIRST_HOUR = 9
    LAST_HOUR = 17
    ZONES = {
      'America/New_York' => %w[CT DC DE FL GA IN KY MA MD ME MI NC NH NJ NY OH PA RI SC VA VT WV],
      'America/Chicago' => %w[AL AR IA IL KS LA MN MO MS ND NE OK SD TN TX WI],
      'America/Denver' => %w[CO ID MT NM UT WY],
      'America/Phoenix' => %w[AZ],
      'America/Los_Angeles' => %w[CA NV OR WA],
      'America/Anchorage' => %w[AK],
      'Pacific/Honolulu' => %w[HI]
    }.freeze

    module_function

    def company_zone(company)
      location = company.locations.find_by(name: company.name) || company.locations.order(:id).first
      ActiveSupport::TimeZone[location&.try(:timezone).presence || 'America/Denver'] || ActiveSupport::TimeZone['America/Denver']
    end

    def lead_zone(lead, company)
      state = lead.try(:state).to_s.strip.upcase
      name = ZONES.find { |_, states| states.include?(state) }&.first
      name ? ActiveSupport::TimeZone[name] : company_zone(company)
    end

    def send_now?(lead, company, at: Time.current)
      local = at.in_time_zone(lead_zone(lead, company))
      (1..5).cover?(local.wday) && local.hour >= FIRST_HOUR && local.hour < LAST_HOUR
    end

    # A reply to someone who just wrote may go out any reasonable hour.
    def reply_now?(lead, company, at: Time.current)
      hour = at.in_time_zone(lead_zone(lead, company)).hour
      hour >= 8 && hour < 21
    end

    def next_reply_time(lead, company, at: Time.current)
      zone = lead_zone(lead, company)
      local = at.in_time_zone(zone)
      morning = zone.local(local.year, local.month, local.day, 8, rand(0..20))
      local.hour < 8 ? morning : morning + 1.day
    end
  end
end
