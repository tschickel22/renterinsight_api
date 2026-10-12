# frozen_string_literal: true

class TourStep < ApplicationRecord
  PLACEMENTS      = %w[top bottom left right center auto].freeze
  HIGHLIGHT_TYPES = %w[outline overlay pulse none].freeze

  belongs_to :tour, inverse_of: :steps

  validates :position,       presence: true, uniqueness: { scope: :tour_id }
  validates :placement,      inclusion: { in: PLACEMENTS }
  validates :highlight_type, inclusion: { in: HIGHLIGHT_TYPES }

  scope :ordered, -> { order(:position) }

  # Dealers get a tour only after a person has played and approved it, so any
  # change to its steps, by whatever path, sends it back for approval. The
  # automated check writes check_status with update_all and does not count.
  NOT_A_CHANGE = %w[check_status checked_at updated_at created_at].freeze

  after_save :unapprove_tours, if: -> { (saved_changes.keys - NOT_A_CHANGE).any? }
  after_destroy :unapprove_tours

  private

  def unapprove_tours
    ids = [tour_id, tour_id_before_last_save].compact.uniq
    Tour.where(id: ids).where.not(approved_at: nil).update_all(approved_at: nil, approved_by_id: nil, updated_at: Time.current)
  end
end
