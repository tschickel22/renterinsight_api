# frozen_string_literal: true

# A frozen point-in-time read of the scanned knowledge state (modules, features,
# permissions). Compared to the prior snapshot during CI to produce change-queue
# items for human review.
class Knowledge::Snapshot < ApplicationRecord
  self.table_name = 'knowledge_snapshots'

  has_many :change_queue_items,
           class_name: 'Knowledge::ChangeQueueItem',
           foreign_key: :knowledge_snapshot_id,
           dependent: :destroy,
           inverse_of: :snapshot

  validates :snapshot_at,  presence: true
  validates :modules_hash, presence: true

  scope :recent,       -> { order(snapshot_at: :desc) }
  scope :with_changes, -> { where("changes_detected::text <> '{}'") }
end
