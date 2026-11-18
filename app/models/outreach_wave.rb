# frozen_string_literal: true

# One group of leads Proactive Outreach works (backlog E105).
class OutreachWave < ApplicationRecord
  STATUSES = %w[building audience_ready drafting review running paused completed failed].freeze
  MAX_SIZE = 100
  MAX_DAILY = 50

  belongs_to :company
  has_many :outreach_targets, foreign_key: :outreach_wave_id, inverse_of: :outreach_wave, dependent: :destroy
  has_many :outreach_events, foreign_key: :outreach_wave_id, inverse_of: :outreach_wave, dependent: :destroy

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :target_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_SIZE }
  validates :daily_limit, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_DAILY }

  def contacted
    outreach_targets.where(test_group: 'contact')
  end

  def held_back
    outreach_targets.where(test_group: 'holdout')
  end
end
