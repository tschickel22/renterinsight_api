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

      if @channel == 'sms'
        if now_local.hour < TCPA_START_HOUR
          return next_send_time(now_local, TCPA_START_HOUR, tz)
        elsif now_local.hour >= TCPA_END_HOUR
          return next_send_time(now_local + 1.day, TCPA_START_HOUR, tz)
        end
      end

      if @send_window['business_hours_only']
        start_h = (@send_window['start_hour'] || (@channel == 'sms' ? TCPA_START_HOUR : 9)).to_i
        end_h = (@send_window['end_hour'] || (@channel == 'sms' ? TCPA_END_HOUR : 18)).to_i
        if now_local.hour < start_h
          return next_send_time(now_local, start_h, tz)
        elsif now_local.hour >= end_h
          return next_send_time(now_local + 1.day, start_h, tz)
        end
        if @send_window['skip_weekends'] && now_local.saturday?
          return next_send_time(now_local + 2.days, start_h, tz)
        elsif @send_window['skip_weekends'] && now_local.sunday?
          return next_send_time(now_local + 1.day, start_h, tz)
        end
      end

      :ok
    end

    private

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
