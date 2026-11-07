# frozen_string_literal: true

require 'net/http'

module CalendarFeeds
  # Reads busy times from a rep's own calendar (E96 phase 2): the private
  # address Google ("Secret address in iCal format") or Outlook ("Publish
  # calendar") gives them. Only start and end are kept, never what an event
  # is. Free (transparent) and cancelled events are skipped. Repeating events
  # are expanded for daily and weekly rules, which covers standing meetings;
  # other rules count their first time only.
  class BusyReader
    WINDOW = 14.days
    MAX_BYTES = 5_000_000
    DAYS = { 'SU' => 0, 'MO' => 1, 'TU' => 2, 'WE' => 3, 'TH' => 4, 'FR' => 5, 'SA' => 6 }.freeze

    class Error < StandardError; end

    def self.sync!(user)
      new(user).sync!
    end

    def initialize(user, body: nil)
      @user = user
      @body = body
    end

    def sync!
      blocks = busy_times(Time.current, Time.current + WINDOW)
      CalendarBusyBlock.transaction do
        CalendarBusyBlock.where(user_id: @user.id, source: 'feed').delete_all
        blocks.first(2000).each do |(s, e)|
          CalendarBusyBlock.create!(company_id: @user.company_id, user_id: @user.id, starts_at: s, ends_at: e, source: 'feed')
        end
      end
      @user.update_columns(busy_feed_checked_at: Time.current, busy_feed_error: nil)
      blocks.size
    rescue StandardError => e
      @user.update_columns(busy_feed_checked_at: Time.current, busy_feed_error: e.message.truncate(200))
      Rails.logger.warn("[CalendarFeeds::BusyReader] user #{@user.id}: #{e.class}: #{e.message}")
      nil
    end

    # [[start, end], ...] overlapping the window.
    def busy_times(from, to)
      events.flat_map { |ev| occurrences(ev, from, to) }.select { |(s, e)| s < to && e > from }.sort
    end

    def events
      lines = unfold(body)
      list = []
      current = nil
      lines.each do |line|
        case line
        when 'BEGIN:VEVENT' then current = {}
        when 'END:VEVENT'
          list << current if current
          current = nil
        else
          next unless current

          name, value = line.split(':', 2)
          key, *params = name.to_s.split(';')
          current[key.upcase] = { value: value.to_s, params: params } if %w[DTSTART DTEND DURATION RRULE TRANSP STATUS].include?(key.upcase)
        end
      end
      list.reject { |e| e.dig('TRANSP', :value) == 'TRANSPARENT' || e.dig('STATUS', :value) == 'CANCELLED' || e['DTSTART'].nil? }
    end

    private

    def body
      @body ||= fetch(@user.busy_feed_url)
    end

    def fetch(url)
      url = url.to_s.strip.sub(/\Awebcal:/i, 'https:')
      SiteProfiles::UrlGuard.validate!(url)
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 20) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      raise Error, "The calendar address answered #{res.code}" unless res.code.to_i.between?(200, 299)
      raise Error, 'The calendar is too large to read' if res.body.to_s.bytesize > MAX_BYTES
      raise Error, 'That address is not a calendar' unless res.body.to_s.include?('BEGIN:VCALENDAR')

      res.body.to_s
    end

    def unfold(text)
      text.to_s.gsub(/\r?\n[ \t]/, '').split(/\r?\n/)
    end

    def occurrences(ev, from, to)
      start, all_day = parse_time(ev['DTSTART'])
      return [] unless start

      finish = if ev['DTEND'] then parse_time(ev['DTEND']).first
               elsif ev['DURATION'] then start + duration(ev.dig('DURATION', :value))
               else start + (all_day ? 1.day : 1.hour)
               end
      finish ||= start + 1.hour
      length = finish - start
      rule = ev.dig('RRULE', :value)
      return [[start, finish]] if rule.blank?

      expand(start, length, rule, from, to)
    end

    def expand(start, length, rule, from, to)
      parts = rule.split(';').to_h { |p| p.split('=', 2) }
      freq = parts['FREQ']
      interval = [parts['INTERVAL'].to_i, 1].max
      count = parts['COUNT']&.to_i
      until_at = parts['UNTIL'] && parse_value(parts['UNTIL'], [])&.first
      stop = [to, until_at].compact.min
      out = []
      n = 0
      case freq
      when 'DAILY'
        t = start
        while t < stop && (count.nil? || n < count)
          out << [t, t + length] if t + length > from
          n += 1
          t += interval.days
        end
      when 'WEEKLY'
        days = (parts['BYDAY'] || '').split(',').filter_map { |d| DAYS[d[-2..]] }
        days = [start.wday] if days.empty?
        week = start.beginning_of_week(:sunday)
        while week < stop && (count.nil? || n < count)
          days.sort.each do |wd|
            t = week + wd.days + (start - start.beginning_of_day)
            next if t < start || t >= stop
            break if count && n >= count

            out << [t, t + length] if t + length > from
            n += 1
          end
          week += interval.weeks
        end
      else
        out << [start, start + length]
      end
      out
    end

    # [time, all_day?]
    def parse_time(field)
      return [nil, false] unless field

      parse_value(field[:value], field[:params])
    end

    def parse_value(value, params)
      tzid = Array(params).find { |p| p.start_with?('TZID=') }&.split('=', 2)&.last
      all_day = Array(params).include?('VALUE=DATE') || value.to_s.match?(/\A\d{8}\z/)
      zone = (tzid && ActiveSupport::TimeZone[tzid]) || ActiveSupport::TimeZone[@user.try(:time_zone).presence || 'UTC'] || Time.zone
      if all_day
        d = Date.strptime(value.to_s[0, 8], '%Y%m%d')
        [zone.local(d.year, d.month, d.day), true]
      elsif value.to_s.end_with?('Z')
        [Time.find_zone('UTC').strptime(value.to_s, '%Y%m%dT%H%M%SZ'), false]
      else
        [zone.strptime(value.to_s[0, 15], '%Y%m%dT%H%M%S'), false]
      end
    rescue ArgumentError
      [nil, false]
    end

    def duration(text)
      m = text.to_s.match(/P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?/)
      return 1.hour unless m

      m[1].to_i.weeks + m[2].to_i.days + m[3].to_i.hours + m[4].to_i.minutes
    end
  end
end
