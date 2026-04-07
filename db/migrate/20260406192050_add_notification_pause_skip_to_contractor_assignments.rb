# frozen_string_literal: true

class AddNotificationPauseSkipToContractorAssignments < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:contractor_assignments, :notification_paused_at)
      add_column :contractor_assignments, :notification_paused_at, :datetime
      add_index  :contractor_assignments, :notification_paused_at
    end

    unless column_exists?(:contractor_assignments, :notification_skipped_at)
      add_column :contractor_assignments, :notification_skipped_at, :datetime
      add_index  :contractor_assignments, :notification_skipped_at
    end
  end
end
