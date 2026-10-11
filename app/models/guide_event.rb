# frozen_string_literal: true

# One page view or marker click (see Guide::UsageRecorder). Raw and short-lived:
# Guide::PruneEventsJob deletes rows older than RETENTION.
class GuideEvent < ApplicationRecord
  KINDS = %w[page click].freeze
  RETENTION = 90.days

  validates :kind, inclusion: { in: KINDS }
end
