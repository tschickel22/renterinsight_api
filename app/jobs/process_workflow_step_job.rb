class ProcessWorkflowStepJob < ApplicationJob
  queue_as :default

  EXECUTOR_MAP = {
    'send_email' => 'WorkflowEngine::StepExecutors::SendEmail',
    'send_sms' => 'WorkflowEngine::StepExecutors::SendSms',
    'update_field' => 'WorkflowEngine::StepExecutors::UpdateField',
    'create_activity' => 'WorkflowEngine::StepExecutors::CreateActivity',
    'wait' => 'WorkflowEngine::StepExecutors::Wait',
    'wait_for_reply' => 'WorkflowEngine::StepExecutors::WaitForReply',
    'branch' => 'WorkflowEngine::StepExecutors::Branch',
    'require_approval' => 'WorkflowEngine::StepExecutors::RequireApproval',
    'enroll_in_nurture' => 'WorkflowEngine::StepExecutors::EnrollInNurture',
    'halt_nurture' => 'WorkflowEngine::StepExecutors::HaltNurture',
    'assign_owner' => 'WorkflowEngine::StepExecutors::AssignOwner',
    'add_tag' => 'WorkflowEngine::StepExecutors::AddTag',
    'remove_tag' => 'WorkflowEngine::StepExecutors::RemoveTag',
    'call_webhook' => 'WorkflowEngine::StepExecutors::CallWebhook',
    'score_entity' => 'WorkflowEngine::StepExecutors::ScoreEntity',
    'classify_reply' => 'WorkflowEngine::StepExecutors::ClassifyReply'
  }.freeze

  def perform(workflow_run_id)
    run = WorkflowRun.find(workflow_run_id)

    if run.status == 'waiting' && run.wait_until && run.wait_until <= Time.current
      Rails.logger.info "[ProcessWorkflowStepJob] run=#{run.id} waking from wait"
      run.update!(status: 'running', wait_until: nil, wait_reason: nil)
    end

    return unless %w[pending running].include?(run.status)

    run.update!(status: 'running') if run.status == 'pending'

    nodes = run.rule_snapshot['nodes'] || []
    node = nodes.find { |n| n['id'] == run.current_step_id }

    unless node
      Rails.logger.info "[ProcessWorkflowStepJob] run=#{run.id} no current node — completing"
      run.complete!
      return
    end

    executor_class_name = EXECUTOR_MAP[node['type'].to_s] || "WorkflowEngine::StepExecutors::#{node['type'].to_s.camelize}"
    executor_class = executor_class_name.constantize
    t0 = Time.current
    # Suppress downstream workflow event emissions caused by this step's own
    # writes, so a rule can't loop by observing its own side effect (e.g.
    # create_activity → touches lead.last_activity_at → re-triggers
    # lead.updated → creates another activity → ...).
    prev_suppress = Current.suppress_workflow_events
    Current.suppress_workflow_events = true
    begin
      result = executor_class.new(run: run, step: node).call
    ensure
      Current.suppress_workflow_events = prev_suppress
    end
    duration = ((Time.current - t0) * 1000).to_i

    run.record_step(
      node['id'],
      node['type'],
      result[:status],
      input: node['config'] || {},
      output: result[:output] || {},
      error: result[:error] || {},
      duration_ms: duration
    )

    if result[:status] == 'failed'
      run.fail!(result[:error] || {})
      return
    end

    if result[:wait]
      attrs = {
        status: 'waiting',
        wait_until: result[:wait][:until],
        wait_reason: result[:wait][:reason]
      }
      # Only advance current_step_id when executor provides one; otherwise
      # stay on the same step (wait_for_reply / require_approval resume paths).
      attrs[:current_step_id] = result[:next_step_id] if result[:next_step_id].present?
      run.update!(attrs)
      return
    end

    if result[:next_step_id]
      run.update!(current_step_id: result[:next_step_id])
      ProcessWorkflowStepJob.perform_later(run.id)
      return
    end

    run.complete!
  rescue => e
    Rails.logger.error "[ProcessWorkflowStepJob] run=#{workflow_run_id} error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    run&.fail!(message: e.message, backtrace: e.backtrace&.first(5))
  end
end
