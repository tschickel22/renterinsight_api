# frozen_string_literal: true

# Whether the person who assigned the contractor wants a copy of the notice.
#
# Stored on the assignment rather than passed through the request because the
# notification is sent asynchronously by ContractorAssignmentNotifierJob, often
# batched — the preference has to outlive the request that set it.
class AddCcAssignerToContractorAssignments < ActiveRecord::Migration[8.0]
  def change
    add_column :contractor_assignments, :cc_assigner, :boolean, default: false, null: false
  end
end
