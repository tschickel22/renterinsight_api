class WorkflowSubscription < ApplicationRecord
  belongs_to :company
  belongs_to :workflow_rule

  scope :for_event, ->(et) { where(event_type: et) }
end
