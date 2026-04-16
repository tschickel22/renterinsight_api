# frozen_string_literal: true

class AddReviewWorkflowFieldsToContractorAssignments < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:contractor_assignments, :completion_photos)
      add_column :contractor_assignments, :completion_photos, :jsonb, default: []
    end

    unless column_exists?(:contractor_assignments, :revision_notes)
      add_column :contractor_assignments, :revision_notes, :text
    end

    unless column_exists?(:contractor_assignments, :revision_count)
      add_column :contractor_assignments, :revision_count, :integer, default: 0
    end

    # Rename submitted_at to submitted_for_review_at for clarity (if old name exists)
    if column_exists?(:contractor_assignments, :submitted_at) && !column_exists?(:contractor_assignments, :submitted_for_review_at)
      rename_column :contractor_assignments, :submitted_at, :submitted_for_review_at
    end

    # Add missing indexes
    unless index_exists?(:contractor_assignments, :review_status)
      add_index :contractor_assignments, :review_status
    end

    unless index_exists?(:contractor_assignments, :reviewed_by_id)
      add_index :contractor_assignments, :reviewed_by_id
    end
  end
end
