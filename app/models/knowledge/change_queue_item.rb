# frozen_string_literal: true

class Knowledge::ChangeQueueItem < ApplicationRecord
  self.table_name = 'knowledge_change_queue'

  CHANGE_TYPES = %w[added removed modified renamed].freeze
  ENTITY_TYPES = %w[module feature permission route ui_element].freeze
  STATUSES     = %w[pending approved rejected auto_applied].freeze

  belongs_to :snapshot,
             class_name: 'Knowledge::Snapshot',
             foreign_key: :knowledge_snapshot_id,
             inverse_of: :change_queue_items

  belongs_to :reviewed_by,
             class_name: 'User',
             optional: true

  validates :change_type, inclusion: { in: CHANGE_TYPES }
  validates :entity_type, inclusion: { in: ENTITY_TYPES }
  validates :entity_key,  presence: true
  validates :status,      inclusion: { in: STATUSES }

  scope :pending,  -> { where(status: 'pending') }
  scope :reviewed, -> { where.not(reviewed_at: nil) }
  scope :for_entity, ->(type, key) { where(entity_type: type, entity_key: key) }

  def approve!(user)
    update!(status: 'approved', reviewed_by: user, reviewed_at: Time.current)
  end

  def reject!(user)
    update!(status: 'rejected', reviewed_by: user, reviewed_at: Time.current)
  end
end
