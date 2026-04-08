class WorkflowRetentionJob < ApplicationJob
  queue_as :default

  def perform
    # Old terminal runs
    WorkflowRun.where(status: %w[completed failed cancelled])
               .where('created_at < ?', 90.days.ago)
               .find_in_batches(batch_size: 200) do |batch|
      batch.each(&:destroy)
    end

    # Old dispatched events
    WorkflowEvent.where('created_at < ? AND dispatched_at IS NOT NULL', 30.days.ago).delete_all

    # Per-rule cap: keep only the 1000 most recent runs per rule
    WorkflowRule.find_each do |rule|
      ids = rule.workflow_runs.order(created_at: :desc).offset(1000).pluck(:id)
      WorkflowRun.where(id: ids).find_each(&:destroy) if ids.any?
    end
  rescue => e
    Rails.logger.error "[WorkflowRetentionJob] #{e.class}: #{e.message}"
  end
end
