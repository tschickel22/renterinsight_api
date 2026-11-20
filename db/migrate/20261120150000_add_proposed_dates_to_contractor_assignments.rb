# frozen_string_literal: true

# E107: a contractor accepts work with a start date, a duration in work days
# and notes. The dates land on the task or phase straight away when it has
# none; otherwise they wait here for the dealer to confirm.
class AddProposedDatesToContractorAssignments < ActiveRecord::Migration[8.0]
  def change
    add_column :contractor_assignments, :proposed_start_date, :date
    add_column :contractor_assignments, :proposed_work_days, :integer
    add_column :contractor_assignments, :proposed_end_date, :date
    add_column :contractor_assignments, :proposed_for, :string # 'task' or 'phase'
    add_column :contractor_assignments, :dates_status, :string # applied, pending, confirmed, declined
    add_column :contractor_assignments, :dates_decided_at, :datetime
    add_column :contractor_assignments, :dates_decided_by_id, :bigint
    add_column :contractor_assignments, :accept_notes, :text
  end
end
