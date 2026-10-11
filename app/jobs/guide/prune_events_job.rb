# frozen_string_literal: true

module Guide
  # Raw usage events are kept 90 days (Tom, 2026-10-11); the rollups stay.
  class PruneEventsJob < ApplicationJob
    queue_as :low

    def perform
      GuideEvent.where('occurred_at < ?', GuideEvent::RETENTION.ago).in_batches(of: 5_000).delete_all
    end
  end
end
