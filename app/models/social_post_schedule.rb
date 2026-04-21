# frozen_string_literal: true

class SocialPostSchedule < ApplicationRecord
  VALID_FREQUENCIES = %w[daily three_per_week weekly biweekly].freeze

  belongs_to :company
  belongs_to :location,    optional: true
  belongs_to :intake_form, optional: true
  belongs_to :notify_user, class_name: 'User', foreign_key: :notify_user_id, optional: true

  validates :frequency, presence: true, inclusion: { in: VALID_FREQUENCIES }

  scope :active,   -> { where(active: true, is_deleted: [false, nil]) }
  scope :due,      ->(now = Time.current) { active.where('next_scheduled_at IS NULL OR next_scheduled_at <= ?', now).where('ends_at IS NULL OR ends_at > ?', now) }

  DAY_NAME_TO_WDAY = {
    'sunday' => 0, 'monday' => 1, 'tuesday' => 2, 'wednesday' => 3,
    'thursday' => 4, 'friday' => 5, 'saturday' => 6
  }.freeze

  # Calculate the next scheduled time from `from` based on frequency / preferred_times / days.
  # Returns a Time in the current zone, always in the future relative to `from`.
  def calculate_next_scheduled_at(from: Time.current)
    times = Array(preferred_times).presence || ['10:00']
    days  = Array(preferred_days).map { |d| d.is_a?(Integer) || d.to_s =~ /\A\d+\z/ ? d.to_i : DAY_NAME_TO_WDAY[d.to_s.downcase] }.compact

    case frequency.to_s
    when 'daily'
      next_slot_on_days(from: from, times: times, days: (0..6).to_a)
    when 'three_per_week', 'weekly'
      days = [1, 3, 5] if days.empty? && frequency == 'three_per_week'
      days = [1]       if days.empty? && frequency == 'weekly'
      next_slot_on_days(from: from, times: times, days: days)
    when 'biweekly'
      base = next_slot_on_days(from: from, times: times, days: days.presence || [1])
      week_delta = anchor_week_offset_even?(base) ? 0 : 7
      base + week_delta.days
    else
      from + 1.day
    end
  end

  private

  def next_slot_on_days(from:, times:, days:)
    times_of_day = times.map { |t| parse_time_of_day(t) }.compact.sort

    candidates = []
    (0..14).each do |offset|
      date = from.to_date + offset
      next unless days.include?(date.wday)
      times_of_day.each do |tod|
        ts = Time.zone.local(date.year, date.month, date.day, tod[0], tod[1])
        candidates << ts if ts > from
      end
    end
    candidates.min
  end

  def parse_time_of_day(value)
    parts = value.to_s.strip.split(':')
    return nil unless parts.length == 2
    [parts[0].to_i, parts[1].to_i]
  end

  def anchor_week_offset_even?(time)
    # Anchor biweekly pacing off created_at so the same row never shifts phase.
    base = created_at || time
    ((time.to_date - base.to_date).to_i / 7).even?
  end
end
