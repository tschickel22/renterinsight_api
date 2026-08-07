# frozen_string_literal: true

# Something a visitor did inside a session on a landing page.
class PageVisitEvent < ApplicationRecord
  belongs_to :page_visit

  # Scroll depth is recorded at milestones rather than continuously — a
  # scroll listener that writes on every frame would generate thousands of
  # rows per visit and tell you nothing more than four of them do.
  SCROLL_EVENTS = %w[scroll_25 scroll_50 scroll_75 scroll_100].freeze

  # Video quartiles are the reason the video block is worth having on a landing
  # page: a page where most visitors reach 75% is working even before anyone
  # submits a form.
  VIDEO_EVENTS = %w[video_play video_25 video_50 video_75 video_complete].freeze

  # form_start fires on first focus, which is what makes abandonment
  # measurable — a page with many starts and few submits has a form problem,
  # not a traffic problem.
  ENGAGEMENT_EVENTS = %w[view cta_click outbound_click form_start form_submit].freeze

  EVENT_TYPES = (SCROLL_EVENTS + VIDEO_EVENTS + ENGAGEMENT_EVENTS).freeze

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :occurred_at, presence: true

  scope :of_type, ->(type) { where(event_type: type) }
  scope :video, -> { where(event_type: VIDEO_EVENTS) }
  scope :scroll, -> { where(event_type: SCROLL_EVENTS) }
end
