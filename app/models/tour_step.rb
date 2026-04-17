# frozen_string_literal: true

class TourStep < ApplicationRecord
  PLACEMENTS      = %w[top bottom left right center auto].freeze
  HIGHLIGHT_TYPES = %w[outline overlay pulse none].freeze

  belongs_to :tour, inverse_of: :steps

  validates :position,       presence: true, uniqueness: { scope: :tour_id }
  validates :placement,      inclusion: { in: PLACEMENTS }
  validates :highlight_type, inclusion: { in: HIGHLIGHT_TYPES }

  scope :ordered, -> { order(:position) }
end
