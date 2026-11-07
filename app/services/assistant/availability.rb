# frozen_string_literal: true

module Assistant
  # Open times for a visit with one rep (E96 phase 2), for Quinn AI to offer.
  #
  # A time is open when it is inside the rep's working hours (their own, else
  # their location's, else nine to five Monday to Saturday), at least the
  # dealer's notice ahead, and clear of the rep's appointments on any record,
  # the time they blocked, and busy times from their own calendar's feed.
  # Our calendar is the source of truth: nothing here reads Google or Outlook
  # beyond the busy feed the rep chose to paste.
  class Availability
    STEP = 30.minutes
    ACTIVITY_MODELS = %w[LeadActivity ContactActivity AccountActivity DealActivity].freeze

    Slot = Struct.new(:id, :starts_at, :ends_at, :label, keyword_init: true)

    def initialize(company:, user:, location: nil, minutes: 60, notice: 2.hours)
      @company = company
      @user = user
      @location = location
      @minutes = minutes.to_i.clamp(15, 240)
      @notice = notice
    end

    def zone
      @zone ||= ActiveSupport::TimeZone[Assistant::Hours.zone_for(@company, location)] || Time.zone
    end

    def location
      @location ||= (@user.try(:location) if @user.try(:location).is_a?(Location)) || Assistant::Hours.pick_location(@company, nil)
    end

    # Open times over the next `days`, at most `per_day` a day, spread over the
    # day (one morning, one afternoon) so the buyer gets a real choice.
    def slots(days: 7, per_day: 2, limit: 8, from: Time.current)
      start = [from + @notice, from].max
      window_end = (from + days.days).end_of_day
      taken = busy(start, window_end)
      found = []
      (0..days).each do |offset|
        day = (from.in_time_zone(zone) + offset.days).to_date
        hours = hours_for(day)
        next unless hours

        open_at, close_at = hours
        candidates = []
        t = open_at
        while t + @minutes.minutes <= close_at
          candidates << t if t >= start && taken.none? { |(b0, b1)| t < b1 && t + @minutes.minutes > b0 }
          t += STEP
        end
        pick(candidates, per_day).each { |c| found << c }
        break if found.size >= limit
      end
      found.first(limit).each_with_index.map do |t, i|
        Slot.new(id: "T#{i + 1}", starts_at: t, ends_at: t + @minutes.minutes, label: t.in_time_zone(zone).strftime('%a %b %-d at %-l:%M %p'))
      end
    end

    # Still open (checked again right before booking).
    def open?(starts_at, ignore: nil)
      ends_at = starts_at + @minutes.minutes
      return false if starts_at < Time.current
      hours = hours_for(starts_at.in_time_zone(zone).to_date)
      return false unless hours && starts_at >= hours[0] && ends_at <= hours[1]

      busy(starts_at, ends_at, ignore: ignore).none? { |(b0, b1)| starts_at < b1 && ends_at > b0 }
    end

    private

    # [open, close] as times in the zone for that day, or nil when closed.
    def hours_for(day)
      table = rep_hours || Assistant::Hours.hours_for(location)
      entry = table ? table[Assistant::Hours::DAYS[day.wday]] : (day.sunday? ? nil : Assistant::Hours::FALLBACK)
      return nil if entry.nil? || entry['closed'] == true || entry['closed'].to_s == 'true'

      open_min = Assistant::Hours.minutes(entry['open'])
      close_min = Assistant::Hours.minutes(entry['close'])
      return nil unless open_min && close_min && close_min > open_min

      base = zone.local(day.year, day.month, day.day)
      [base + open_min.minutes, base + close_min.minutes]
    end

    def rep_hours
      hours = @user.try(:working_hours)
      hours.is_a?(Hash) && hours.any? ? hours.stringify_keys : nil
    end

    # Morning and afternoon when there are both.
    def pick(candidates, per_day)
      return candidates.first(per_day) if candidates.size <= per_day || per_day < 2

      noon = candidates.first.in_time_zone(zone).change(hour: 12)
      morning = candidates.find { |c| c < noon }
      afternoon = candidates.find { |c| c >= noon + 1.hour } || candidates.reverse.find { |c| c >= noon }
      [morning, afternoon].compact.uniq.presence&.first(per_day) || candidates.first(per_day)
    end

    # [[start, end], ...] the rep is not free.
    def busy(from, to, ignore: nil)
      return [] unless @user

      list = CalendarBusyBlock.where(user_id: @user.id).overlapping(from, to).pluck(:starts_at, :ends_at)
      ACTIVITY_MODELS.each do |name|
        model = name.safe_constantize
        next unless model && model.column_names.include?('start_time')

        scope = model.where(activity_type: 'meeting').where.not(status: %w[cancelled completed])
                     .where('start_time < ? AND start_time > ?', to, from - 1.day)
        scope = scope.where('assigned_to_id = :id OR (assigned_to_id IS NULL AND user_id = :id)', id: @user.id)
        scope = scope.where.not(id: ignore.id) if ignore.is_a?(model)
        # Deal activities have no duration column.
        cols = model.column_names.include?('duration_minutes') ? %i[start_time end_time duration_minutes] : %i[start_time end_time]
        scope.pluck(*cols).each do |s, e, mins|
          finish = e || (s + (mins.presence || 60).to_i.minutes)
          list << [s, finish] if finish > from
        end
      end
      list
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Availability] busy lookup failed for user #{@user&.id}: #{e.class}: #{e.message}")
      []
    end
  end
end
