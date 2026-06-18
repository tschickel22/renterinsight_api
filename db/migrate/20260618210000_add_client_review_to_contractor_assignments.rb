# frozen_string_literal: true

# Customer-facing approval gate for contractor work, layered on top of the
# existing dealer review workflow. Only populated when the company setting
# project_management.require_client_approval is on AND the assignable is a
# ProjectPhaseTask. The customer becomes gate 1 (approve / reject / revise);
# the dealer remains the closing gate 2 via approve_review!.
class AddClientReviewToContractorAssignments < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:contractor_assignments, :client_review_required)
      add_column :contractor_assignments, :client_review_required, :boolean, default: false, null: false
    end

    unless column_exists?(:contractor_assignments, :client_review_status)
      # nil = no customer gate; otherwise pending / approved / revision_requested / rejected
      add_column :contractor_assignments, :client_review_status, :string
    end

    unless column_exists?(:contractor_assignments, :client_reviewed_at)
      add_column :contractor_assignments, :client_reviewed_at, :datetime
    end

    unless column_exists?(:contractor_assignments, :client_review_notes)
      add_column :contractor_assignments, :client_review_notes, :text
    end

    # When the dealer records the customer's decision on their behalf (verbal /
    # in-person approval, or customer non-response), this stores which dealer user
    # acted. nil = the customer acted themselves via the portal/public page.
    unless column_exists?(:contractor_assignments, :acted_on_behalf_by_id)
      add_column :contractor_assignments, :acted_on_behalf_by_id, :bigint
    end

    unless index_exists?(:contractor_assignments, :client_review_status)
      add_index :contractor_assignments, :client_review_status
    end

    unless index_exists?(:contractor_assignments, :acted_on_behalf_by_id)
      add_index :contractor_assignments, :acted_on_behalf_by_id
    end
  end
end
