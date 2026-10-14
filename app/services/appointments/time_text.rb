# frozen_string_literal: true

module Appointments
  # "Tue Oct 14 at 3:00 PM", in the company's time zone.
  module TimeText
    def self.for(activity, company)
      activity.start_time.in_time_zone(company&.time_zone.presence || 'UTC').strftime('%a %b %-d at %-l:%M %p')
    end
  end
end
