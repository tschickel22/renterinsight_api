class NurtureStep < ApplicationRecord
  belongs_to :nurture_sequence

  STEP_TYPES = %w[email sms wait call].freeze
  validates :step_type, presence: true, inclusion: { in: STEP_TYPES }
  validates :position, presence: true
end
