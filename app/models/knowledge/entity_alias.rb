# frozen_string_literal: true

# NOTE: The column is `alias_name` rather than `alias` because `alias` is a
# Ruby reserved keyword and can't be called as a method. Reads/writes go through
# `record.alias_name`, with `record.alias` aliased below for callers who prefer
# the original name (accessed via `send(:alias)`).
class Knowledge::EntityAlias < ApplicationRecord
  self.table_name = 'knowledge_entity_aliases'

  ENTITY_TYPES = %w[module feature model permission action route].freeze

  validates :canonical_key, presence: true
  validates :alias_name,    presence: true, uniqueness: { scope: :entity_type }
  validates :entity_type,   inclusion: { in: ENTITY_TYPES }

  scope :of_type,        ->(type) { where(entity_type: type) }
  scope :for_canonical,  ->(key)  { where(canonical_key: key) }
end
