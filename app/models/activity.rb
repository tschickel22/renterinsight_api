# frozen_string_literal: true

class Activity < ApplicationRecord
  belongs_to :lead, inverse_of: :activities
  belongs_to :user, optional: true

  VALID_TYPES    = %w[call email meeting note status_change form_submission website_visit sms nurture_email ai_suggestion lead_activity_task lead_activity_meeting lead_activity_call lead_activity_reminder].freeze
  VALID_OUTCOMES = %w[positive neutral negative].freeze

  validates :activity_type, presence: true, inclusion: { in: VALID_TYPES }
  validates :description, presence: true
  validates :outcome, inclusion: { in: VALID_OUTCOMES }, allow_nil: true

  scope :recent,   -> { order(created_at: :desc) }
  scope :for_lead, ->(lead_id) { where(lead_id: lead_id) }
  scope :by_type,  ->(type) { where(activity_type: type) }
end
