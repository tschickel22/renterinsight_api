# frozen_string_literal: true

module Guide
  # Looks for a new frontend build every few minutes (see Guide::ReleaseWatcher).
  class ReleaseWatchJob < ApplicationJob
    queue_as :low

    def perform
      Guide::ReleaseWatcher.new.run
    end
  end
end
