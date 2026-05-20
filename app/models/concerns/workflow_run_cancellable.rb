module WorkflowRunCancellable
  extend ActiveSupport::Concern

  included do
    before_destroy :cancel_active_workflow_runs, unless: -> { skip_workflows }
  end

  private

  def cancel_active_workflow_runs
    return unless self.class.name.present? && id.present?
    WorkflowRun.where(entity_type: self.class.name, entity_id: id)
               .where.not(status: %w[completed failed cancelled])
               .find_each do |run|
      run.update_columns(
        status: 'cancelled',
        completed_at: Time.current,
        error_details: { reason: 'entity_deleted' }
      )
    end
  rescue => e
    Rails.logger.error "[WorkflowRunCancellable] #{self.class}##{id} failed: #{e.message}"
  end
end
