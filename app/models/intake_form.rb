class IntakeForm < ApplicationRecord
  has_many :intake_submissions, dependent: :destroy
  validates :name, presence: true
end
