module Messaging
  class SendWindowCalculator
    TCPA_START_HOUR = 8
    TCPA_END_HOUR = 21

    STATE_TZ = {
      'AL' => 'Central Time (US & Canada)', 'AK' => 'Alaska', 'AZ' => 'Arizona',
      'AR' => 'Central Time (US & Canada)', 'CA' => 'Pacific Time (US & Canada)',
      'CO' => 'Mountain Time (US & Canada)', 'CT' => 'Eastern Time (US & Canada)',
      'DE' => 'Eastern Time (US & Canada)', 'FL' => 'Eastern Time (US & Canada)',
      'GA' => 'Eastern Time (US & Canada)', 'HI' => 'Hawaii',
      'ID' => 'Mountain Time (US & Canada)', 'IL' => 'Central Time (US & Canada)',
      'IN' => 'Eastern Time (US & Canada)', 'IA' => 'Central Time (US & Canada)',
      'KS' => 'Central Time (US & Canada)', 'KY' => 'Eastern Time (US & Canada)',
      'LA' => 'Central Time (US & Canada)', 'ME' => 'Eastern Time (US & Canada)',
      'MD' => 'Eastern Time (US & Canada)', 'MA' => 'Eastern Time (US & Canada)',
      'MI' => 'Eastern Time (US & Canada)', 'MN' => 'Central Time (US & Canada)',
      'MS' => 'Central Time (US & Canada)', 'MO' => 'Central Time (US & Canada)',
      'MT' => 'Mountain Time (US & Canada)', 'NE' => 'Central Time (US & Canada)',
      'NV' => 'Pacific Time (US & Canada)', 'NH' => 'Eastern Time (US & Canada)',
      'NJ' => 'Eastern Time (US & Canada)', 'NM' => 'Mountain Time (US & Canada)',
      'NY' => 'Eastern Time (US & Canada)', 'NC' => 'Eastern Time (US & Canada)',
      'ND' => 'Central Time (US & Canada)', 'OH' => 'Eastern Time (US & Canada)',
      'OK' => 'Central Time (US & Canada)', 'OR' => 'Pacific Time (US & Canada)',
      'PA' => 'Eastern Time (US & Canada)', 'RI' => 'Eastern Time (US & Canada)',
      'SC' => 'Eastern Time (US & Canada)', 'SD' => 'Central Time (US & Canada)',
      'TN' => 'Central Time (US & Canada)', 'TX' => 'Central Time (US & Canada)',
      'UT' => 'Mountain Time (US & Canada)', 'VT' => 'Eastern Time (US & Canada)',
      'VA' => 'Eastern Time (US & Canada)', 'WA' => 'Pacific Time (US & Canada)',
      'WV' => 'Eastern Time (US & Canada)', 'WI' => 'Central Time (US & Canada)',
      'WY' => 'Mountain Time (US & Canada)'
    }.freeze

    def initialize(send_window:, channel:, recipient: nil, company: nil, now: Time.current)
      @send_window = send_window.is_a?(Hash) ? send_window : {}
      @channel = channel.to_s
      @recipient = recipient
      @company = company
      @now = now
    end

    def evaluate
      tz = recipient_timezone
      now_local = @now.in_time_zone(tz)

      # TCPA is a legal floor on the RECIPIENT's local clock, so it is evaluated before and
      # independently of the tenant's own window and never uses the window's timezone.
      if @channel == 'sms'
        if now_local.hour < TCPA_START_HOUR
          return next_send_time(now_local, TCPA_START_HOUR, tz)
        elsif now_local.hour >= TCPA_END_HOUR
          return next_send_time(now_local + 1.day, TCPA_START_HOUR, tz)
        end
      end

      return :ok unless business_window?

      window_tz = window_time_zone || tz
      local = @now.in_time_zone(window_tz)
      start_h = window_start_hour
      end_h = window_end_hour

      candidate =
        if hours_bounded?(start_h, end_h) && local.hour < start_h
          local.change(hour: start_h, min: 0, sec: 0)
        elsif hours_bounded?(start_h, end_h) && local.hour >= end_h
          (local + 1.day).change(hour: start_h, min: 0, sec: 0)
        else
          local
        end

      candidate = next_allowed_day(candidate, allowed_days, start_h)
      return :ok if candidate == local

      candidate.in_time_zone(window_tz)
    end

    private

    # Two vocabularies reached this column. The campaign UI writes business_hours_only with
    # start_hour/end_hour/skip_weekends; older rows carry hour_start/hour_end/days/timezone.
    # Only the first was ever read, so every campaign configured the older way had no window
    # at all: seven of them were live in production, sending at any hour on any day while
    # their settings screen showed weekdays nine to four.
    LEGACY_KEYS = %w[hour_start hour_end days start_hour end_hour].freeze

    DAY_NUMBERS = {
      'sun' => 0, 'mon' => 1, 'tue' => 2, 'wed' => 3, 'thu' => 4, 'fri' => 5, 'sat' => 6
    }.freeze

    def business_window?
      flag = @send_window['business_hours_only']
      # An explicit false is the UI's "no window" toggle and outranks any hours left behind
      # in the row from when it was on.
      return false if flag == false
      return true if flag

      LEGACY_KEYS.any? { |key| @send_window[key].present? }
    end

    def window_start_hour
      (@send_window['start_hour'] || @send_window['hour_start'] ||
        (@channel == 'sms' ? TCPA_START_HOUR : 9)).to_i
    end

    def window_end_hour
      (@send_window['end_hour'] || @send_window['hour_end'] ||
        (@channel == 'sms' ? TCPA_END_HOUR : 18)).to_i
    end

    # A window that ends before it starts cannot be satisfied, and enforcing it would defer
    # every enrollment forever, one day at a time. Treat the hours as unset and let any day
    # restriction stand on its own.
    def hours_bounded?(start_h, end_h)
      end_h > start_h
    end

    # @return [Array<Integer>, nil] weekday numbers that are allowed, or nil for no restriction
    def allowed_days
      raw = @send_window['days']
      if raw.is_a?(Array) && raw.any?
        # Unparseable names produce an empty list, which would block every day of the week.
        # Falling back to no restriction keeps a typo from silently freezing a campaign.
        return raw.filter_map { |d| DAY_NUMBERS[d.to_s.strip.downcase[0, 3]] }.uniq.presence
      end

      return [1, 2, 3, 4, 5] if @send_window['skip_weekends']

      nil
    end

    def next_allowed_day(time, days, start_hour)
      return time if days.blank?

      7.times do
        return time if days.include?(time.wday)

        time = (time + 1.day).change(hour: start_hour, min: 0, sec: 0)
      end
      time
    end

    # Only honoured when it is a timezone Rails actually knows; an unrecognised string would
    # otherwise raise deep inside in_time_zone and take the send with it.
    def window_time_zone
      name = @send_window['timezone'].presence
      return nil if name.blank?

      ActiveSupport::TimeZone[name] ? name : nil
    end

    def recipient_timezone
      tz = @recipient&.try(:time_zone)
      return tz if tz.present?

      state = @recipient&.try(:state) || @recipient&.try(:address_state)
      tz = STATE_TZ[state.to_s.upcase] if state.present?
      return tz if tz.present?

      tz = @company&.try(:time_zone)
      return tz if tz.present?

      'Eastern Time (US & Canada)'
    end

    def next_send_time(base_local, hour, tz)
      base_local.change(hour: hour, min: 0).in_time_zone(tz)
    end
  end
end
