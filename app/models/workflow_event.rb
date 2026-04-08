class WorkflowEvent < ApplicationRecord
  belongs_to :company

  scope :undispatched, -> { where(dispatched_at: nil) }
end
