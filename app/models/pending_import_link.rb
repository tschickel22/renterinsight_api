# frozen_string_literal: true

# A deferred import lookup. Created when the Importer cannot resolve a parent
# association at import time (parent not yet uploaded, or a transient name
# mismatch). A resolver sweep back-fills the child's foreign key once a matching
# parent appears -- within the same import or in a later upload session.
#
# Lifecycle:
#   pending   -> created when a lookup misses
#   resolved  -> parent found, child's *_id back-filled, resolved_at/parent set
#   abandoned -> optional terminal state for cleanup of stale links
class PendingImportLink < ApplicationRecord
  belongs_to :company
  belongs_to :import_job, optional: true

  STATUSES = %w[pending resolved abandoned].freeze

  validates :entity_type, :entity_id, :target_column,
            :parent_model, :lookup_value, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending,  -> { where(status: 'pending') }
  scope :resolved, -> { where(status: 'resolved') }
  scope :for_parent_model, ->(model) { where(parent_model: model.to_s) }

  # The child record this link is attached to (e.g. the ServiceTicket).
  # Resolved lazily and company-scoped via the stored type/id.
  def entity_record
    klass = entity_type.safe_constantize
    return nil unless klass
    klass.where(company_id: company_id).find_by(id: entity_id)
  end

  def mark_resolved!(parent)
    update!(status: 'resolved', resolved_at: Time.current, resolved_parent_id: parent.id)
  end
end
