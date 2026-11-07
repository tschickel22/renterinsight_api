# frozen_string_literal: true

# Someone who gets a client's daily onboarding summary without being
# assigned anything: a person at the client, or one of us.
class OnboardingFollower < ApplicationRecord
  belongs_to :company
  belongs_to :user

  validates :user_id, uniqueness: { scope: :company_id }
end
