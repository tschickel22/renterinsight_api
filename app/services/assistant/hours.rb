# frozen_string_literal: true

module Assistant
  # Whether the dealer is open right now, for Quinn's "book only after hours"
  # goal (E96). Read from the location's business hours in its own time zone,
  # else the company's first location with hours, else nine to five Monday to
  # Saturday in the company's time zone.
  #
  # Hours are stored per day: { "monday" => { "open" => "09:00",
  # "close" => "17:00", "closed" => false }, ... }.
  module Hours
    DAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze
    FALLBACK = { 'open' => '09:00', 'close' => '17:00' }.freeze

    module_function

    def open_now?(company, location = nil, at: Time.current)
      location = pick_location(company, location)
      zone = zone_for(company, location)
      local = at.in_time_zone(zone)
      day = hours_for(location)&.dig(DAYS[local.wday])
      day = (local.sunday? ? nil : FALLBACK) if hours_for(location).nil?
      return false if day.nil? || day['closed'] == true || day['closed'].to_s == 'true'

      open = minutes(day['open'])
      close = minutes(day['close'])
      return false unless open && close && close > open

      now = local.hour * 60 + local.min
      now >= open && now < close
    rescue StandardError
      true
    end

    def pick_location(company, location)
      return location if location.is_a?(Location) && location.business_hours.present?

      company.locations.where.not(business_hours: {}).order(:id).first || (location if location.is_a?(Location))
    rescue StandardError
      location
    end

    def hours_for(location)
      hours = location&.business_hours
      hours.is_a?(Hash) && hours.any? ? hours.stringify_keys : nil
    end

    def zone_for(company, location)
      zone = location.try(:timezone).presence
      zone = nil if zone && ActiveSupport::TimeZone[zone].nil?
      zone || company&.time_zone.presence || 'UTC'
    end

    def minutes(text)
      h, m = text.to_s.split(':').map(&:to_i)
      return nil if text.blank? || h.nil?

      h * 60 + m.to_i
    end
  end
end
