# frozen_string_literal: true

class AccountingImport < ApplicationRecord
  belongs_to :company
  belongs_to :user

  SOURCE_TYPES = %w[quickbooks_online quickbooks_desktop freshbooks csv].freeze
  STATUSES = %w[pending in_progress completed failed partial].freeze

  validates :source_type, presence: true, inclusion: { in: SOURCE_TYPES }
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def in_progress?
    status == 'in_progress'
  end

  def mark_started!
    update!(status: 'in_progress', started_at: Time.current)
  end

  def mark_completed!(results_hash)
    totals = results_hash.values.select { |v| v.is_a?(Hash) }
    update!(
      status: totals.any? { |t| t[:errors]&.positive? } ? 'partial' : 'completed',
      results: results_hash,
      total_imported: totals.sum { |t| t[:imported] || 0 },
      total_skipped: totals.sum { |t| t[:skipped] || 0 },
      total_errors: totals.sum { |t| t[:errors] || 0 },
      completed_at: Time.current
    )
  end

  def mark_failed!(error_message)
    update!(
      status: 'failed',
      errors_log: (errors_log || []) + [{ error: error_message, at: Time.current.iso8601 }],
      total_errors: (total_errors || 0) + 1,
      completed_at: Time.current
    )
  end

  def add_error(entity_type, identifier, message)
    self.errors_log = (errors_log || []) + [{
      entity_type: entity_type,
      identifier: identifier.to_s,
      error: message,
      at: Time.current.iso8601
    }]
    save
  end
end
