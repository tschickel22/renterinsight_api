class NurtureEnrollment < ApplicationRecord
  belongs_to :lead
  belongs_to :nurture_sequence

  STATUSES = %w[idle running paused completed].freeze
  validates :status, presence: true, inclusion: { in: STATUSES }
end
