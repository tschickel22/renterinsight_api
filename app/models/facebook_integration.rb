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
  # Newest-first. Connecting a Page retires the company's previous one, so there
  # is normally a single active row — but rows connected before that retirement
  # existed must not outrank the Page the user just picked.
  scope :current, -> { active.order(created_at: :desc, id: :desc) }

  # The company's live Facebook connection. Every consumer (publisher, comment
  # sync, ads, status tiles) must resolve through here so they all agree on
  # which Page is "the" Page.
  def self.current_for(company)
    return nil if company.nil?

    company.facebook_integrations.current.first
  end

  def token_expired?
    token_expires_at.present? && token_expires_at <= Time.current
  end

  def token_expiring_soon?(threshold = 7.days)
    token_expires_at.present? && token_expires_at <= threshold.from_now
  end
end
