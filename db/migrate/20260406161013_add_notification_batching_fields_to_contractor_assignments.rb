# frozen_string_literal: true

class AddNotificationBatchingFieldsToContractorAssignments < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:contractor_assignments, :notified_at)
      add_column :contractor_assignments, :notified_at, :datetime
      add_index  :contractor_assignments, :notified_at
    end

    unless column_exists?(:contractor_assignments, :review_notified_at)
      add_column :contractor_assignments, :review_notified_at, :datetime
      add_index  :contractor_assignments, :review_notified_at
    end
  end
end
