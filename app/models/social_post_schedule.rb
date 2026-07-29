# frozen_string_literal: true

class SocialPostSchedule < ApplicationRecord
  # one_time fires once at run_at and then deactivates itself. It exists so a
  # user can schedule a single post for later — the composer could only publish
  # now or save a draft, and every other frequency is a recurring cadence.
  VALID_FREQUENCIES = %w[one_time daily three_per_week weekly biweekly].freeze

  belongs_to :company
  belongs_to :location,    optional: true
  belongs_to :intake_form, optional: true
  belongs_to :notify_user, class_name: 'User', foreign_key: :notify_user_id, optional: true
  # Only set on one_time schedules, where the user picks the exact unit to
  # feature instead of letting the picker draw from inventory.
  belongs_to :vehicle,     optional: true

  validates :frequency, presence: true, inclusion: { in: VALID_FREQUENCIES }
  validates :run_at, presence: true, if: :one_time?
  validate  :inventory_statuses_are_known

  # `due` treats a null next_scheduled_at as "run now", so a one-time schedule
  # created without one would fire on the next tick instead of at run_at. Pin it
  # here rather than in the controller so every caller gets it right.
  before_save :pin_one_time_next_run

  def one_time?
    frequency.to_s == 'one_time'
  end

  # A one-time schedule is the user explicitly asking for this post at this
  # time, so there is nobody left to approve it — it publishes on its own.
  # Recurring schedules keep their auto_approve setting.
  def effective_auto_approve?
    one_time? || auto_approve
  end

  scope :active,   -> { where(active: true, is_deleted: [false, nil]) }
  scope :due,      ->(now = Time.current) { active.where('next_scheduled_at IS NULL OR next_scheduled_at <= ?', now).where('ends_at IS NULL OR ends_at > ?', now) }

  DAY_NAME_TO_WDAY = {
    'sunday' => 0, 'monday' => 1, 'tuesday' => 2, 'wednesday' => 3,
    'thursday' => 4, 'friday' => 5, 'saturday' => 6
  }.freeze

  # Calculate the next scheduled time from `from` based on frequency / preferred_times / days.
  # Returns a Time in the current zone, always in the future relative to `from`.
  def calculate_next_scheduled_at(from: Time.current)
    # A one-time schedule has an exact moment rather than a recurring slot, and
    # never yields a next run — the job deactivates it once it has fired.
    return run_at if one_time?

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

  # Statuses the vehicle picker may draw from. Falls back to 'available' so a
  # schedule that predates the column behaves exactly as it did before.
  def selectable_inventory_statuses
    Array(inventory_statuses).map(&:to_s).select { |s| Vehicle::STATUSES.include?(s) }.presence || ['available']
  end

  # Next image from the operator-supplied pool, round-robin so a schedule with
  # several images cycles through them instead of reusing the first one.
  # Advances the cursor as a side effect; returns nil when the pool is empty.
  def next_pool_image!
    pool = Array(image_pool).map { |u| u.to_s.strip }.reject(&:blank?)
    return nil if pool.empty?

    idx = image_pool_cursor.to_i % pool.length
    update_column(:image_pool_cursor, (idx + 1) % pool.length)
    pool[idx]
  end

  private

  def pin_one_time_next_run
    return unless one_time? && active?
    return unless will_save_change_to_run_at? || next_scheduled_at.blank?

    self.next_scheduled_at = run_at
  end

  def inventory_statuses_are_known
    unknown = Array(inventory_statuses).map(&:to_s) - Vehicle::STATUSES
    return if unknown.empty?

    errors.add(:inventory_statuses, "contains unknown status: #{unknown.join(', ')}")
  end

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
