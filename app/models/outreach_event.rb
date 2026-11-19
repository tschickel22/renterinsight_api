# frozen_string_literal: true

# Something that happened to a lead in a wave (backlog E105). The daily results
# are counted from these.
class OutreachEvent < ApplicationRecord
  TYPES = %w[sent delivered opened clicked replied booked held no_show converted unsubscribed bounced undelivered
             complained handed_off skipped report_viewed scan_requested].freeze

  belongs_to :outreach_wave
  belongs_to :outreach_target

  validates :event_type, inclusion: { in: TYPES }
end
