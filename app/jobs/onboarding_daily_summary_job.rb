# frozen_string_literal: true

# Each morning's onboarding summary emails (Onboarding::DailySummary, E97).
class OnboardingDailySummaryJob < ApplicationJob
  queue_as :low

  def perform
    Onboarding::DailySummary.call
  end
end
