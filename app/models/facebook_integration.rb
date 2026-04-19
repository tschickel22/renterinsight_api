# frozen_string_literal: true

class FacebookIntegration < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :default_source, class_name: 'Source', optional: true
  belongs_to :default_owner,  class_name: 'User',   optional: true
  belongs_to :default_workflow, class_name: 'WorkflowRule', foreign_key: 'default_workflow_id', optional: true

  encrypts :page_access_token
  encrypts :user_access_token

  validates :page_id, presence: true

  scope :active, -> { where(status: 'active', is_deleted: [false, nil]) }

  def token_expired?
    token_expires_at.present? && token_expires_at <= Time.current
  end

  def token_expiring_soon?(threshold = 7.days)
    token_expires_at.present? && token_expires_at <= threshold.from_now
  end
end
