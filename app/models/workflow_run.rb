class WorkflowRun < ApplicationRecord
  STATUSES = %w[pending running waiting paused completed failed cancelled].freeze

  belongs_to :company
  belongs_to :workflow_rule
  belongs_to :parent_run, class_name: 'WorkflowRun', optional: true
  belongs_to :entity, polymorphic: true, foreign_key: :entity_id, foreign_type: :entity_type, optional: true

  has_many :workflow_run_steps, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: %w[pending running waiting]) }
  scope :due_for_resume, -> { where(status: 'waiting', wait_reason: %w[delay reply_pause approval]).where('wait_until <= ?', Time.current) }

  after_update_commit :fire_status_webhook

  def fire_status_webhook
    return unless saved_change_to_status?
    return unless defined?(WebhookService)
    event = case status
            when 'running'   then 'workflow_run.started'
            when 'completed' then 'workflow_run.completed'
            when 'failed'    then 'workflow_run.failed'
            end
    return unless event
    WebhookService.fire(
      company_id: company_id,
      event: event,
      payload: {
        id: id,
        workflow_rule_id: workflow_rule_id,
        status: status,
        entity_type: entity_type,
        entity_id: entity_id,
        started_at: started_at,
        completed_at: completed_at,
        error_details: error_details
      }
    )
  rescue => e
    Rails.logger.error "[WorkflowRun##{id}] fire_status_webhook failed: #{e.message}"
  end

  def record_step(step_id, step_type, status, input:, output: {}, error: {}, duration_ms: nil)
    workflow_run_steps.create!(
      step_id: step_id,
      step_type: step_type,
      status: status,
      input: input,
      output: output,
      error: error,
      duration_ms: duration_ms,
      started_at: Time.current,
      completed_at: Time.current
    )
  end

  def fail!(error_hash)
    update!(status: 'failed', error_details: error_hash, completed_at: Time.current)
  end

  def complete!
    update!(status: 'completed', completed_at: Time.current)
  end
end
