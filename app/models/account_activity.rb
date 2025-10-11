class AccountActivity < ApplicationRecord
  belongs_to :account
  belongs_to :user, optional: true

  ACTIVITY_TYPES = %w[call email meeting note status_change].freeze
  OUTCOMES = %w[positive neutral negative].freeze

  validates :activity_type, presence: true, inclusion: { in: ACTIVITY_TYPES }
  validates :description, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }, allow_blank: true
  validates :duration, numericality: { greater_than_or_equal_to: 0 }, allow_blank: true

  scope :recent, -> { order(created_at: :desc) }
  scope :by_type, ->(type) { where(activity_type: type) }
  scope :with_outcome, -> { where.not(outcome: nil) }
end
