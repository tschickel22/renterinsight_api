# frozen_string_literal: true

# A rep following a lead, account, contact or deal (backlog E86). Followers
# hear about the record like its owner does (Followable#notify_audience) and
# can open it even outside their own locations.
class RecordFollower < ApplicationRecord
  FOLLOWABLE_TYPES = %w[Lead Account Contact Deal].freeze

  belongs_to :company
  belongs_to :followable, polymorphic: true
  belongs_to :user

  validates :followable_type, inclusion: { in: FOLLOWABLE_TYPES }
  validates :user_id, uniqueness: { scope: %i[followable_type followable_id] }
  validate :user_in_same_company

  private

  def user_in_same_company
    return if user.nil? || company_id.nil?

    errors.add(:user, 'must belong to the same company') unless user.company_id == company_id
  end
end
