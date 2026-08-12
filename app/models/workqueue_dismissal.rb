# frozen_string_literal: true

# A record a user has set aside while working through their Workqueue.
#
# Not a delete and not a snooze until some arbitrary date. It records WHEN the
# user dealt with the record, and every queue then compares that moment against
# the freshness of whatever put the row in front of them: the engagement event,
# the click, the last activity on the record. Anything newer wins and the row
# comes back on its own.
#
# That is what makes "remove for now" honest. A rep can clear the queue down to
# the untouched items without hiding a lead who replies an hour later.
class WorkqueueDismissal < ApplicationRecord
  belongs_to :company
  belongs_to :user

  validates :entity_type, presence: true
  validates :entity_id, presence: true
  validates :dismissed_at, presence: true
  validates :entity_id, uniqueness: { scope: %i[user_id entity_type] }

  # Entity types a row can carry. Workqueue rows are these models or resolve to
  # them, and an unknown type would silently never match anything, so it is
  # rejected at the door instead.
  ENTITY_TYPES = %w[Lead Contact Account Deal ServiceTicket Quote Invoice WorkqueueActivity].freeze

  validates :entity_type, inclusion: { in: ENTITY_TYPES }

  # Dismissing something already dismissed moves the marker forward rather than
  # failing on the unique index. The user is telling us they handled it again.
  def self.dismiss!(company:, user:, entity_type:, entity_id:, at: Time.current)
    record = find_or_initialize_by(user_id: user.id, entity_type: entity_type, entity_id: entity_id)
    record.company_id = company.id
    record.dismissed_at = at
    record.save!
    record
  end

  scope :for_user, ->(user) { where(user_id: user.id) }
end
