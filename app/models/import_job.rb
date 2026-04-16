# frozen_string_literal: true

class ImportJob < ApplicationRecord
  belongs_to :company
  belongs_to :user

  STATUSES = %w[pending processing completed failed rolled_back].freeze
  DUPLICATE_STRATEGIES = %w[skip update create_new error].freeze

  validates :module_type, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :duplicate_strategy, inclusion: { in: DUPLICATE_STRATEGIES }, allow_nil: true

  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where(status: %w[pending processing]) }
  scope :rollbackable, -> {
    where(status: 'completed').where("jsonb_array_length(created_record_ids) > 0")
  }

  ROLLBACK_WINDOW = 30.days

  def can_rollback?
    return false unless status == 'completed'
    return false unless completed_at && completed_at > ROLLBACK_WINDOW.ago
    created_record_ids.is_a?(Array) && created_record_ids.any?
  end

  def progress_percent
    return 0 if total_rows.to_i.zero?
    ((processed_rows.to_f / total_rows) * 100).round(1)
  end
end
