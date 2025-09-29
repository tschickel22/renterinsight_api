class IntakeSubmission < ApplicationRecord
  belongs_to :intake_form
  belongs_to :lead, optional: true
  validates :payload, presence: true
end
