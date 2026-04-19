# frozen_string_literal: true

class Knowledge::IntentPattern < ApplicationRecord
  self.table_name = 'knowledge_intent_patterns'

  INTENT_TYPES = %w[navigate create update delete search report help explain configure].freeze

  validates :pattern,     presence: true
  validates :intent_type, inclusion: { in: INTENT_TYPES }

  scope :ordered_by_priority, -> { order(priority: :desc, id: :asc) }
  scope :for_intent,          ->(type) { where(intent_type: type) }
  scope :for_entity,          ->(key)  { where(entity_key: key) }

  # Test this pattern against a user query string. Returns true on match.
  def matches?(text)
    return false if pattern.blank? || text.blank?
    Regexp.new(pattern, Regexp::IGNORECASE).match?(text)
  rescue RegexpError
    false
  end
end
