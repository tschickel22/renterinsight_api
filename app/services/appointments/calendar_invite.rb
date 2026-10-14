# frozen_string_literal: true

module Appointments
  # A calendar invite (.ics) for an appointment, emailed to the person it is
  # assigned to and, when the appointment says so, to the customer.
  #
  # Our Google and Microsoft connections cannot write calendars, so this is
  # the sync: one way, from DealerTide. The UID stays the same and SEQUENCE
  # rises on every change, so calendars update the event in place; a cancel
  # or delete sends METHOD:CANCEL. Changes made in a calendar do not come
  # back, so appointments are changed here.
  #
  # The appointment belongs to the rep it is assigned to, never to whoever
  # booked it. The two copies differ on purpose:
  # - The customer's copy is organized by the assigned rep (and sent from the
  #   rep's own mailbox when connected), so the customer's replies and RSVPs
  #   reach the rep.
  # - The rep's copy is organized by the company's sending address with the
  #   rep as the attendee. Calendars do not add an invite whose organizer is
  #   the reader, so a rep-organized copy sent to the rep never lands.
  class CalendarInvite
    FIELDS = %w[start_time end_time meeting_location location subject description status assigned_to_id].freeze

    attr_reader :activity, :method

    def initialize(activity, method: 'REQUEST', sequence: nil)
      @activity = activity
      @method = method
      @sequence = sequence
    end

    def uid
      "dealertide-#{activity.class.name.underscore.dasherize}-#{activity.id}@#{host}"
    end

    def sequence
      @sequence || activity.customer_notices.to_h.dig('invite', 'sequence').to_i
    end

    def assignee
      activity.assigned_to || activity.user
    end

    def customer
      @customer ||= Customer.for(activity)
    end

    # [[email, name, :rep | :customer, user_or_nil], ...]
    def recipients
      list = []
      list << [assignee.email, assignee.try(:full_name).presence || assignee.email, :rep, assignee] if assignee&.email.present?
      if activity.try(:send_calendar_invite) && customer&.email.present? && customer.company &&
         ReminderSettings.for(customer.company)['invites'] &&
         !CampaignSuppression.unmailable?(customer.company.id, customer.email)
        list << [customer.email, customer.name || customer.email, :customer, nil]
      end
      list.uniq { |r| r[0].downcase }
    end

    # organizer: [email, name]; attendees: [[email, name], ...]
    def to_ics(organizer:, attendees:)
      company = customer&.company
      title = "#{activity.subject}#{" with #{company.name}" if company && customer&.name.nil?}"
      lines = [
        'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//DealerTide//Appointments//EN', "METHOD:#{method}", 'CALSCALE:GREGORIAN',
        'BEGIN:VEVENT',
        "UID:#{uid}",
        "SEQUENCE:#{sequence}",
        "DTSTAMP:#{utc(Time.current)}",
        "DTSTART:#{utc(activity.start_time)}",
        "DTEND:#{utc(activity.end_time || (activity.start_time + 1.hour))}",
        "SUMMARY:#{escape(title)}",
        ("LOCATION:#{escape(place)}" if place.present?),
        ("DESCRIPTION:#{escape(activity.description)}" if activity.description.present?),
        ("ORGANIZER;CN=#{escape(organizer[1])}:mailto:#{organizer[0]}" if organizer&.first.present?),
        *attendees.map { |email, name| "ATTENDEE;CN=#{escape(name)};ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:#{email}" },
        "STATUS:#{method == 'CANCEL' ? 'CANCELLED' : 'CONFIRMED'}",
        'END:VEVENT', 'END:VCALENDAR'
      ].compact
      lines.map { |l| fold(l) }.join("\r\n") + "\r\n"
    end

    # Deal activities call the column location; the others meeting_location.
    def place
      activity.try(:meeting_location).presence || activity.try(:location).presence
    end

    private

    def host
      URI.parse(Brand.current.app_url.to_s).host.presence || 'dealertide.com'
    rescue StandardError
      'dealertide.com'
    end

    def utc(time) = time.utc.strftime('%Y%m%dT%H%M%SZ')

    def escape(text)
      text.to_s.gsub('\\', '\\\\\\\\').gsub("\n", '\\n').gsub(',', '\\,').gsub(';', '\;')
    end

    # RFC 5545: lines over 75 octets continue on the next with a space.
    def fold(line)
      return line if line.bytesize <= 75

      out = +''
      current = +''
      line.each_char do |ch|
        if (current + ch).bytesize > 74
          out << current << "\r\n "
          current = +''
        end
        current << ch
      end
      out << current
    end
  end
end
