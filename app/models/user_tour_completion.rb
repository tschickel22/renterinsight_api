# frozen_string_literal: true

# Tracks a given user's progress through a tour. `steps_completed` is a jsonb
# map of step identifier → completion metadata, e.g.
#   { "1" => {"completed_at": "...", "skipped": false}, ... }
class UserTourCompletion < ApplicationRecord
  belongs_to :user
  belongs_to :tour, inverse_of: :completions

  validates :user_id, uniqueness: { scope: :tour_id }

  scope :completed, -> { where.not(completed_at: nil) }
  scope :pending,   -> { where(completed_at: nil) }

  def completed?
    completed_at.present?
  end
end
