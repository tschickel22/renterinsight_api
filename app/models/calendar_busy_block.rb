# frozen_string_literal: true

# Time a rep is not free for a visit (E96 phase 2): blocked by hand in
# DealerTide, or read from their own calendar's private feed.
#
# Feed rows carry a title and place only when the rep chose to show them
# (User#busy_feed_detail), because their calendar can be opened by managers
# and admins. Descriptions, guests and meeting links are never kept.
class CalendarBusyBlock < ApplicationRecord
  SOURCES = %w[manual feed].freeze
  # none:          read for Quinn AI only, not shown on the DealerTide calendar
  # busy:          shown as Busy
  # titles:        shown with the event's title
  # titles_places: shown with the event's title and where it is
  FEED_DETAILS = %w[none busy titles titles_places].freeze

  # What the owner's choice allows of a stored row, so lowering the choice hides
  # more at once, before the next read rewrites the rows.
  def self.shown_title(detail, title)
    return nil if detail.to_s == 'none'
    return 'Busy' if detail.to_s == 'busy'

    title.presence || 'Busy'
  end

  def self.shown_place(detail, place)
    detail.to_s == 'titles_places' ? place.presence : nil
  end

  belongs_to :company
  belongs_to :user

  validates :source, inclusion: { in: SOURCES }
  validates :starts_at, :ends_at, presence: true
  validate { errors.add(:ends_at, 'must be after the start') if starts_at && ends_at && ends_at <= starts_at }

  scope :overlapping, ->(from, to) { where('starts_at < ? AND ends_at > ?', to, from) }
end
