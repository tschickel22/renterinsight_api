# frozen_string_literal: true

module Guide
  # Monday's help digest (see Guide::WeeklyDigest).
  class WeeklyDigestJob < ApplicationJob
    queue_as :low

    def perform(force = false)
      Guide::WeeklyDigest.new(force: force).run
    end
  end
end
