# frozen_string_literal: true

# A tour reaches dealers only after a person has played it and approved it
# (Tom, 2026-10-11). The automated check proves each step's element exists;
# it cannot tell whether the tour teaches the task, which two AI-built tours
# that passed it did not. Changing a tour's steps clears the approval.
class AddApprovalToTours < ActiveRecord::Migration[8.0]
  def change
    add_column :tours, :approved_at, :datetime
    add_column :tours, :approved_by_id, :bigint
  end
end
