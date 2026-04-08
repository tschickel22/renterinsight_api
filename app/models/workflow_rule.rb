# halt_on_reply: 'false' | 'true' | 'branch'
# Reply detection uses Communication#communication_thread_id linkage
# (outbound comms tagged with workflow_run_id, matched against inbound replies),
# NOT WorkflowSubscription-based event subscriptions.
class WorkflowRule < ApplicationRecord
  belongs_to :company
  belongs_to :created_by_user, class_name: 'User', optional: true

  has_many :workflow_runs, dependent: :destroy
  has_many :workflow_subscriptions, dependent: :destroy

  validates :name, :entity_type, :status, presence: true
  validates :status, inclusion: { in: %w[draft active paused archived] }

  scope :active, -> { where(status: 'active') }

  after_save :sync_subscriptions
  after_update_commit :fire_status_webhook

  def fire_status_webhook
    return unless saved_change_to_status?
    return unless defined?(WebhookService)
    event = case status
            when 'active' then 'workflow_rule.activated'
            when 'paused' then 'workflow_rule.paused'
            end
    return unless event
    WebhookService.fire(
      company_id: company_id,
      event: event,
      payload: { id: id, name: name, entity_type: entity_type, status: status }
    )
  rescue => e
    Rails.logger.error "[WorkflowRule##{id}] fire_status_webhook failed: #{e.message}"
  end

  def snapshot_steps
    steps.deep_dup
  end

  private

  def sync_subscriptions
    workflow_subscriptions.destroy_all
    return unless status == 'active'
    event_type = trigger.is_a?(Hash) ? trigger['event_type'] : nil
    return if event_type.blank?

    workflow_subscriptions.create!(
      company_id: company_id,
      event_type: event_type,
      entity_type_filter: trigger['entity_type_filter']
    )
  rescue => e
    Rails.logger.error "[WorkflowRule##{id}] sync_subscriptions failed: #{e.message}"
  end
end
