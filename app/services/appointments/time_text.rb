# frozen_string_literal: true

module Appointments
  # "Tue Oct 14 at 3:00 PM", in the time zone of the location the customer
  # belongs to, else the company's. The company setting defaults to Eastern,
  # so a Denver lead's 4 PM visit used to be texted and emailed as 6 PM.
  module TimeText
    def self.for(activity, company)
      activity.start_time.in_time_zone(zone_for(activity, company)).strftime('%a %b %-d at %-l:%M %p')
    end

    def self.zone_for(activity, company)
      record = activity.try(:lead) || activity.try(:contact) || activity.try(:account) || activity.try(:deal)
      location = record.try(:location)
      zone = location.try(:timezone).presence if location.is_a?(Location)
      zone = nil if zone && ActiveSupport::TimeZone[zone].nil?
      zone || company&.time_zone.presence || 'UTC'
    end
  end
end
