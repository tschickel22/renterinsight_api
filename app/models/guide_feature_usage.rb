# frozen_string_literal: true

# Per-person rollup of guide_events: when someone first and last used a part of
# the product, and how often. Read by checklists, coaching and adoption views.
class GuideFeatureUsage < ApplicationRecord
  belongs_to :user
end
