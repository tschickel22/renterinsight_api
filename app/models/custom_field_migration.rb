# frozen_string_literal: true

class CustomFieldMigration < ApplicationRecord
  belongs_to :source_custom_field, class_name: 'CustomField'
  belongs_to :target_custom_field, class_name: 'CustomField', optional: true
  belongs_to :company

  TARGET_MODULES = %w[contacts accounts deals].freeze
  MIGRATION_TYPES = %w[create_new map_to_existing skip].freeze

  validates :target_module, presence: true, inclusion: { in: TARGET_MODULES }
  validates :migration_type, presence: true, inclusion: { in: MIGRATION_TYPES }
  validates :source_custom_field_id, uniqueness: { scope: :target_module, message: 'already has a migration for this target module' }
  validates :target_custom_field, presence: true, if: -> { migration_type == 'map_to_existing' }

  scope :for_company, ->(company) { where(company: company) }
  scope :active, -> { where.not(migration_type: 'skip') }

  def skip?
    migration_type == 'skip'
  end
end
