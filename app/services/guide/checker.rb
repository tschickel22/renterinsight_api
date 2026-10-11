# frozen_string_literal: true

module Guide
  # The account the nightly tour check signs in as (backlog E75, phase 5):
  # a company admin on a test dealership, named in GUIDE_CHECK_EMAIL on the
  # server. It may list tours for checking and record what it found, even
  # while tours are paused, and nothing it does counts as product usage.
  module Checker
    def self.user?(user)
      email = ENV['GUIDE_CHECK_EMAIL'].to_s.strip
      email.present? && user.present? && user.email.to_s.casecmp?(email)
    end
  end
end
