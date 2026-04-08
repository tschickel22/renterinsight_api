module WorkflowEngine
  module_function

  def emit(event_type, entity, payload = {})
    return if entity.nil?
    company_id = entity.respond_to?(:company_id) ? entity.company_id : nil
    return if company_id.nil?

    event = WorkflowEvent.create!(
      company_id: company_id,
      event_type: event_type,
      entity_type: entity.class.name,
      entity_id: entity.id,
      payload: payload
    )
    DispatchWorkflowEventsJob.perform_later
    event
  rescue => e
    Rails.logger.error "[WorkflowEngine.emit] #{event_type} failed: #{e.message}"
    nil
  end

  def start_run(rule:, entity:, event: nil)
    run = WorkflowRun.create!(
      company_id: rule.company_id,
      workflow_rule_id: rule.id,
      entity_type: entity.class.name,
      entity_id: entity.id,
      status: 'pending',
      current_step_id: rule_entry_step_id(rule),
      variables: build_initial_variables(entity, event),
      rule_snapshot: rule.snapshot_steps,
      started_at: Time.current
    )
    Rails.logger.info "[WorkflowEngine] Started run #{run.id} for rule #{rule.id} entity=#{entity.class.name}##{entity.id}"
    ProcessWorkflowStepJob.perform_later(run.id)
    run
  end

  def resume(run, additional_variables: {})
    return unless run.status == 'waiting'
    run.update!(
      status: 'running',
      wait_until: nil,
      wait_reason: nil,
      variables: run.variables.deep_merge(additional_variables)
    )
    Rails.logger.info "[WorkflowEngine] Resuming run #{run.id}"
    ProcessWorkflowStepJob.perform_later(run.id)
  end

  def handle_inbound_reply(workflow_run_id:, inbound_communication:)
    run = WorkflowRun.find_by(id: workflow_run_id)
    return unless run
    reply_company_id = inbound_communication.communicable&.try(:company_id)
    return unless run.company_id == reply_company_id

    reply_vars = {
      'channel' => inbound_communication.channel,
      'body' => inbound_communication.body,
      'subject' => inbound_communication.subject,
      'received_at' => (inbound_communication.created_at || Time.current).iso8601
    }

    if run.status == 'waiting' && run.wait_reason == 'reply_pause'
      resume(run, additional_variables: { 'reply' => reply_vars })
      return
    end

    return unless %w[running waiting pending].include?(run.status)
    rule = run.workflow_rule
    case rule.halt_on_reply.to_s
    when 'true'
      cancel(run, reason: 'halted_on_reply')
    when 'branch'
      run.update!(variables: run.variables.merge('reply_received' => true, 'reply' => reply_vars))
    end
  rescue => e
    Rails.logger.error "[WorkflowEngine.handle_inbound_reply] failed: #{e.message}"
  end

  def cancel(run, reason: 'manual')
    return if %w[completed failed cancelled].include?(run.status)
    run.update!(status: 'cancelled', completed_at: Time.current, error_details: { reason: reason })
    Rails.logger.info "[WorkflowEngine] Cancelled run #{run.id} reason=#{reason}"
  end

  class << self
    private

    def rule_entry_step_id(rule)
      (rule.steps['nodes'] || []).first&.dig('id')
    end

    def build_initial_variables(entity, event)
      {
        'entity' => entity.as_json,
        'trigger' => event&.payload || {},
        'started_at' => Time.current.iso8601
      }
    end
  end
end
