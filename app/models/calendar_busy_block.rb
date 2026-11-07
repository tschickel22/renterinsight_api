# frozen_string_literal: true

# Time a rep is not free for a visit (E96 phase 2): blocked by hand in
# DealerTide, or read from their own calendar's private feed (busy times only,
# never what the event is).
class CalendarBusyBlock < ApplicationRecord
  SOURCES = %w[manual feed].freeze

  belongs_to :company
  belongs_to :user

  validates :source, inclusion: { in: SOURCES }
  validates :starts_at, :ends_at, presence: true
  validate { errors.add(:ends_at, 'must be after the start') if starts_at && ends_at && ends_at <= starts_at }

  scope :overlapping, ->(from, to) { where('starts_at < ? AND ends_at > ?', to, from) }
end
