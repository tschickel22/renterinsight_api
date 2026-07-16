module WorkflowEngine
  module_function

  def emit(event_type, entity, payload = {})
    return if entity.nil?

    # Loop guard: if a workflow step is currently executing and its side
    # effects are what caused this event, don't fan out another dispatch —
    # otherwise rules that trigger on lead.updated with an is_set condition
    # form an infinite loop against their own writes.
    if defined?(Current) && Current.suppress_workflow_events
      Rails.logger.debug "[WorkflowEngine.emit] suppressed #{event_type} for #{entity.class.name}##{entity.id} (inside workflow step)"
      return nil
    end

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
      variables: build_initial_variables(entity, event).merge('params' => rule.parameters || {}),
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

  # Called from Branch and other executors that need a fresh, denormalized
  # snapshot of an entity outside of the initial run.variables. Delegates to
  # the private helper so we don't duplicate the denormalization logic.
  def self.entity_hash(entity)
    return {} if entity.nil?
    entity_as_hash_with_denormalized(entity)
  end

  class << self
    private

    def rule_entry_step_id(rule)
      (rule.steps['nodes'] || []).first&.dig('id')
    end

    RELATED_ENTITY_ASSOCIATIONS = {
      'Lead'          => { 'home' => :vehicle, 'account' => :converted_account },
      'Deal'          => { 'account' => :account, 'contact' => :contact, 'home' => :vehicle },
      'Contact'       => { 'account' => :account },
      # ServiceTicket carries its own location, so expose it as {{location.*}}
      # for templates that want to route by shop/branch.
      'ServiceTicket' => { 'contact' => :contact, 'account' => :account, 'home' => :vehicle, 'deal' => :deal, 'location' => :location },
      'Listing'       => { 'home' => :vehicle },
      'Account'       => {},
      'Vehicle'       => {}
    }.freeze

    def build_initial_variables(entity, event)
      vars = {
        'entity' => entity_as_hash_with_denormalized(entity),
        'trigger' => event&.payload || {},
        'started_at' => Time.current.iso8601,
        'frontend_url' => ENV['FRONTEND_URL'].presence || 'https://localhost:5173'
      }
      # Activity-scoped triggers (e.g. lead_activity.created) carry the child
      # record inside the event payload. Hoist it to a top-level {{activity.*}}
      # so templates and update_field steps can reference it directly.
      if (activity_payload = event&.payload&.dig('activity')).is_a?(Hash)
        vars['activity'] = activity_payload
      end
      vars.merge!(related_entity_snapshots(entity))
      vars
    end

    def entity_as_hash_with_denormalized(entity)
      hash = (entity.respond_to?(:as_json) ? entity.as_json : {}) || {}

      if entity.respond_to?(:first_name)
        hash['full_name'] ||= full_name_for(entity)
      end

      if entity.respond_to?(:owner) && (owner = entity.try(:owner))
        hash['owner_email'] ||= owner.try(:email)
        hash['owner_phone'] ||= owner.try(:phone)
        hash['owner_name']  ||= full_name_for(owner) || owner.try(:email)
      end

      account = entity.try(:account) || entity.try(:converted_account)
      hash['account_name'] ||= account.try(:name) if account

      if (contact = entity.try(:contact))
        hash['contact_email']      ||= contact.try(:email)
        hash['contact_first_name'] ||= contact.try(:first_name)
        hash['contact_last_name']  ||= contact.try(:last_name)
      end

      if (assignee = entity.try(:assigned_to_user) || entity.try(:assigned_to))
        hash['assigned_to_name'] ||= full_name_for(assignee) || assignee.try(:email)
      end

      if entity.is_a?(Listing) && (vehicle = entity.try(:vehicle))
        hash['url']     ||= vehicle.try(:listing_url)
        hash['address'] ||= vehicle.try(:address1)
      end

      hash
    end

    def related_entity_snapshots(entity)
      mappings = RELATED_ENTITY_ASSOCIATIONS[entity.class.name] || {}
      mappings.each_with_object({}) do |(key, assoc), acc|
        record = entity.try(assoc)
        next unless record
        acc[key] = entity_as_hash_with_denormalized(record)
      end
    end

    def full_name_for(record)
      return nil unless record
      first = record.try(:first_name)
      last  = record.try(:last_name)
      [first, last].compact.reject(&:blank?).join(' ').presence
    end
  end
end
