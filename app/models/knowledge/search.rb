# frozen_string_literal: true

# Append-only analytics log for smart-help search queries.
class Knowledge::Search < ApplicationRecord
  self.table_name = 'knowledge_searches'

  # No updated_at on this table.
  self.record_timestamps = false

  belongs_to :user, optional: true

  validates :query, presence: true

  before_validation :stamp_created_at, on: :create

  scope :recent, -> { order(created_at: :desc) }
  scope :with_intent, ->(type) { where(intent_detected: type) }

  private

  def stamp_created_at
    self.created_at ||= Time.current
  end
end
