# frozen_string_literal: true

module CalendarFeeds
  # A rep's DealerTide appointments as a calendar feed (E96 phase 2): the
  # private link they subscribe to in Google Calendar, Outlook or an iPhone,
  # so visits Quinn AI or anyone books show up on their own calendar. Read
  # only; the link's token is the only key, and the rep can make a new one.
  class IcsOut
    MODELS = %w[LeadActivity ContactActivity AccountActivity DealActivity].freeze
    PAST = 30.days
    AHEAD = 180.days
    # What the link carries (users.calendar_feed_includes, E108).
    INCLUDES = %w[meetings meetings_and_projects].freeze

    def initialize(user)
      @user = user
    end

    def to_ics
      lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', "PRODID:-//#{Brand.current.name}//Appointments//EN", 'CALSCALE:GREGORIAN',
               'METHOD:PUBLISH', "X-WR-CALNAME:#{escape("#{Brand.current.name} #{projects? ? 'appointments and projects' : 'appointments'}")}"]
      events.each { |e| lines.concat(vevent(e)) }
      project_work.each { |e| lines.concat(all_day_vevent(e)) } if projects?
      lines << 'END:VCALENDAR'
      lines.map { |l| fold(l) }.join("\r\n") + "\r\n"
    end

    def events
      MODELS.flat_map do |name|
        model = name.safe_constantize
        next [] unless model

        model.where(activity_type: 'meeting').where.not(status: 'cancelled').where.not(start_time: nil)
             .where(start_time: (Time.current - PAST)..(Time.current + AHEAD))
             .where('assigned_to_id = :id OR (assigned_to_id IS NULL AND user_id = :id)', id: @user.id)
             .limit(1000).to_a
      end
    end

    def projects?
      @user.try(:calendar_feed_includes) == 'meetings_and_projects'
    end

    # The person's project work (E108): the same phases and tasks their My
    # calendar shows in DealerTide, in their own company.
    def project_work
      company = @user.company
      return [] unless company

      events = ProjectCalendarEvents.new(projects: company.projects, user_ids: [@user.id],
                                         from: Time.current - PAST, to: Time.current + AHEAD)
      (events.phases.to_a + events.tasks.to_a).reject { |r| %w[completed skipped].include?(r.status) }
    end

    private

    # Phases and tasks are whole days: DTEND is the day after the last one.
    def all_day_vevent(record)
      first, last = ProjectCalendarEvents.span(record)
      phase = record.is_a?(ProjectPhase) ? record : record.project_phase
      project = phase.project
      who = project.customer_name.presence || project.name
      summary = "#{record.name}: #{who}"
      out = ['BEGIN:VEVENT', "UID:dt-#{record.class.name.underscore}-#{record.id}@#{host}",
             "DTSTAMP:#{utc(record.updated_at || Time.current)}",
             "DTSTART;VALUE=DATE:#{first.strftime('%Y%m%d')}", "DTEND;VALUE=DATE:#{(last + 1).strftime('%Y%m%d')}",
             "SUMMARY:#{escape(summary)}"]
      place = [project.try(:delivery_street), project.try(:delivery_city), project.try(:delivery_state)].compact_blank.join(', ')
      out << "LOCATION:#{escape(place)}" if place.present?
      out << "DESCRIPTION:#{escape([project.name, (phase.name unless record == phase)].compact_blank.join(', '))}"
      out << 'END:VEVENT'
    end

    def vevent(activity)
      finish = activity.end_time || (activity.start_time + (activity.try(:duration_minutes).presence || 60).to_i.minutes)
      out = ['BEGIN:VEVENT', "UID:dt-#{activity.class.name.underscore}-#{activity.id}@#{host}",
             "DTSTAMP:#{utc(activity.updated_at || Time.current)}", "DTSTART:#{utc(activity.start_time)}", "DTEND:#{utc(finish)}",
             "SUMMARY:#{escape(activity.subject)}"]
      out << "LOCATION:#{escape(activity.meeting_location)}" if activity.try(:meeting_location).present?
      out << "DESCRIPTION:#{escape(activity.description.to_s.truncate(500))}" if activity.description.present?
      out << 'END:VEVENT'
    end

    def host
      URI.parse(Brand.current.website_url.to_s).host.presence || 'dealertide.com'
    rescue URI::InvalidURIError
      'dealertide.com'
    end

    def utc(time) = time.utc.strftime('%Y%m%dT%H%M%SZ')

    def escape(text)
      text.to_s.gsub('\\', '\\\\\\\\').gsub(';', '\;').gsub(',', '\,').gsub(/\r?\n/, '\n')
    end

    # Lines over 75 octets continue on the next line after a space (RFC 5545).
    def fold(line)
      return line if line.bytesize <= 75

      parts = []
      current = +''
      line.each_char do |ch|
        if (current + ch).bytesize > 74
          parts << current
          current = +' '
        end
        current << ch
      end
      parts << current
      parts.join("\r\n")
    end
  end
end
