class Activity < ApplicationRecord
  belongs_to :lead
  # If there’s a user_id column but no users table/model in dev, keep this optional.
  # Remove this line if you don’t have a user_id column.
  belongs_to :user, optional: true

  # Keep validations tight so controller errors are clear.
  validates :activity_type, presence: true,
            inclusion: {
              in: %w[
                call email meeting note status_change
                form_submission website_visit sms
                nurture_email ai_suggestion
              ]
            }

  # Optional, but nice to have:
  validates :description, length: { maximum: 2000 }, allow_nil: true
end
