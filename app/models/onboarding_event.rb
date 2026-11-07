# frozen_string_literal: true

# What happened on a client's onboarding list, by whom and from which side:
# the activity feed, the notes, and what the daily summary reports.
class OnboardingEvent < ApplicationRecord
  KINDS = %w[added done reopened not_needed note upload assigned].freeze
  SIDES = %w[client dealertide].freeze

  belongs_to :company
  belongs_to :onboarding_item, optional: true
  belongs_to :user, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :side, inclusion: { in: SIDES }
end
