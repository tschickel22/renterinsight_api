# frozen_string_literal: true

# A named list of users to round-robin lead assignments across. Referenced
# from both api_keys.webhook_config (inbound webhooks) and workflow AssignOwner
# action nodes so tokens and workflows share one cursor and one "skip inactive"
# rule per company.
#
# Cursor advancement is atomic and skips users who are inactive (status != 'active').
# If all users are inactive, returns nil — callers should treat that as "leave
# unassigned" rather than crashing.
class RoundRobinAssignmentList < ApplicationRecord
  belongs_to :company

  validates :name, presence: true
  validates :name, uniqueness: { scope: :company_id }
  validate :user_ids_are_array

  scope :active, -> { where(active: true) }

  # Atomically pick the next active user in the list and advance the cursor.
  # Skips users whose status != 'active'. Wraps around at the end. Returns nil
  # if the list is empty or every configured user is inactive.
  def next_active_user!
    with_lock do
      ids = Array(user_ids).map(&:to_i)
      return nil if ids.empty?

      active_ids = User.where(id: ids, status: 'active').pluck(:id)
      return nil if active_ids.empty?

      # Preserve the caller's configured ordering while filtering to actives.
      ordered_actives = ids.select { |id| active_ids.include?(id) }
      idx = cursor.to_i % ordered_actives.length
      picked_id = ordered_actives[idx]
      update_column(:cursor, (idx + 1) % ordered_actives.length)
      User.find_by(id: picked_id)
    end
  end

  private

  def user_ids_are_array
    return if user_ids.is_a?(Array)
    errors.add(:user_ids, 'must be an array')
  end
end
