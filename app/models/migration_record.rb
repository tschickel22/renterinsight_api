# frozen_string_literal: true

# One record brought in by a data migration, keyed by its id in the source
# system. See CreateMigrationRecords.
class MigrationRecord < ApplicationRecord
  belongs_to :company

  validates :source_system, :source_type, :source_id, :record_type, :record_id, :loaded_at, presence: true

  scope :for_source, ->(system) { where(source_system: system) }
end
