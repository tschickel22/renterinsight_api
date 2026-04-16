# frozen_string_literal: true

class AddReviewFieldsToContractorAssignments < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:contractor_assignments, :submitted_for_review)
      add_column :contractor_assignments, :submitted_for_review, :boolean, default: false
    end

    unless column_exists?(:contractor_assignments, :submitted_at)
      add_column :contractor_assignments, :submitted_at, :datetime
    end

    unless column_exists?(:contractor_assignments, :review_status)
      add_column :contractor_assignments, :review_status, :string
    end

    unless column_exists?(:contractor_assignments, :reviewed_at)
      add_column :contractor_assignments, :reviewed_at, :datetime
    end

    unless column_exists?(:contractor_assignments, :reviewed_by_id)
      add_column :contractor_assignments, :reviewed_by_id, :bigint
    end

    unless column_exists?(:contractor_assignments, :review_notes)
      add_column :contractor_assignments, :review_notes, :text
    end

    unless column_exists?(:contractor_assignments, :completion_summary)
      add_column :contractor_assignments, :completion_summary, :text
    end
  end
end
