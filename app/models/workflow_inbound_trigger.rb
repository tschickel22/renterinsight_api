class WorkflowInboundTrigger < ApplicationRecord
  belongs_to :company
  belongs_to :workflow_rule

  before_validation :generate_token, on: :create

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end
end
