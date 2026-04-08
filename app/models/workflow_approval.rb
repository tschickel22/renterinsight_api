class WorkflowApproval < ApplicationRecord
  STATUSES = %w[pending approved rejected expired].freeze

  belongs_to :company
  belongs_to :workflow_run
  belongs_to :approver_user, class_name: 'User', optional: true
end
