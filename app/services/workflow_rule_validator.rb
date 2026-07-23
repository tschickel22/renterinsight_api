# frozen_string_literal: true

class WorkflowRuleValidator
  KNOWN_EVENT_TYPES = %w[
    lead.created lead.updated lead.deleted lead.status_changed
    deal.created deal.updated deal.deleted deal.status_changed
    contact.created contact.updated contact.deleted contact.status_changed
    account.created account.updated account.deleted account.status_changed
    service_ticket.created service_ticket.updated service_ticket.status_changed
    lead_activity.created lead_activity.updated lead_activity.completed
    deal_activity.created deal_activity.updated deal_activity.completed
    contact_activity.created contact_activity.updated contact_activity.completed
    account_activity.created account_activity.updated account_activity.completed
    inbound.webhook
    cron.minutely cron.hourly cron.daily cron.weekly
  ].freeze

  VALID_STEP_TYPES = %w[
    send_email send_sms update_field create_activity wait
    wait_for_reply branch require_approval
    enroll_in_nurture halt_nurture
    assign_owner add_tag remove_tag call_webhook
    score_entity classify_reply
  ].freeze

  attr_reader :errors, :warnings, :structured_errors

  def initialize(rule)
    @rule = rule
    @errors = []
    @structured_errors = []
    @warnings = []
  end

  def validate
    validate_trigger
    validate_steps_structure
    if @errors.empty?
      validate_step_types
      validate_step_configs
      validate_no_orphan_nodes
      validate_reachability
    end
    self
  end

  def valid?
    @errors.empty?
  end

  private

  def add_error(message, step_id: nil, step_type: nil, field: nil)
    @errors << message
    @structured_errors << {
      step_id: step_id,
      step_type: step_type,
      field: field,
      message: message
    }
  end

  def nodes
    steps_hash = @rule.steps.is_a?(Hash) ? @rule.steps : {}
    steps_hash['nodes'].is_a?(Array) ? steps_hash['nodes'] : []
  end

  def edges
    steps_hash = @rule.steps.is_a?(Hash) ? @rule.steps : {}
    steps_hash['edges'].is_a?(Array) ? steps_hash['edges'] : []
  end

  def validate_trigger
    trig = @rule.trigger
    unless trig.is_a?(Hash)
      add_error('Trigger must be a Hash', step_type: 'trigger')
      return
    end
    if trig['event_type'].blank?
      add_error("Trigger must have an 'event_type'", step_type: 'trigger', field: 'event_type')
      return
    end
    unless KNOWN_EVENT_TYPES.include?(trig['event_type'])
      @warnings << "Trigger event_type '#{trig['event_type']}' is not in the known event list"
    end
  end

  def validate_steps_structure
    s = @rule.steps
    unless s.is_a?(Hash)
      add_error("Steps must be a Hash with 'nodes' and 'edges'", step_type: 'steps')
      return
    end
    unless s['nodes'].is_a?(Array)
      add_error("Steps 'nodes' must be an Array", step_type: 'steps', field: 'nodes')
    end
    unless s['edges'].is_a?(Array)
      add_error("Steps 'edges' must be an Array", step_type: 'steps', field: 'edges')
    end
  end

  def validate_step_types
    nodes.each do |node|
      unless node.is_a?(Hash) && node['id'].present?
        add_error("Each node must be a Hash with an 'id'", field: 'id')
        next
      end
      type = node['type']
      if type.blank?
        add_error("Node '#{node['id']}' is missing a 'type'", step_id: node['id'], field: 'type')
      elsif !VALID_STEP_TYPES.include?(type)
        add_error("Node '#{node['id']}' has invalid step type '#{type}'", step_id: node['id'], step_type: type, field: 'type')
      end
    end
  end

  def validate_step_configs
    nodes.each do |node|
      next unless node.is_a?(Hash)
      cfg = node['config'] || node['data'] || {}
      cfg = {} unless cfg.is_a?(Hash)
      id = node['id']
      type = node['type']
      case type
      when 'send_email'
        %w[to subject body].each do |k|
          if cfg[k].blank?
            add_error("Node '#{id}' (send_email) is missing required config '#{k}'", step_id: id, step_type: type, field: k)
          end
        end
      when 'send_sms'
        %w[to body].each do |k|
          if cfg[k].blank?
            add_error("Node '#{id}' (send_sms) is missing required config '#{k}'", step_id: id, step_type: type, field: k)
          end
        end
      when 'update_field'
        if !cfg['fields'].is_a?(Hash) || cfg['fields'].empty?
          add_error("Node '#{id}' (update_field) requires a non-empty 'fields' Hash", step_id: id, step_type: type, field: 'fields')
        end
      when 'create_activity'
        %w[activity_type subject].each do |k|
          if cfg[k].blank?
            add_error("Node '#{id}' (create_activity) is missing required config '#{k}'", step_id: id, step_type: type, field: k)
          end
        end
        # Warn early when the step will silently no-op because the rule's
        # entity type has no matching activity model (e.g. ServiceTicket).
        supported = %w[Lead Deal Contact Account]
        if @rule.entity_type.present? && !supported.include?(@rule.entity_type)
          add_warning("Node '#{id}' (create_activity) does nothing for entity type '#{@rule.entity_type}' — only supported for: #{supported.join(', ')}")
        end
      when 'wait'
        if cfg['duration'].blank?
          add_error("Node '#{id}' (wait) requires 'duration'", step_id: id, step_type: type, field: 'duration')
        end
        if cfg['unit'].blank?
          add_error("Node '#{id}' (wait) requires 'unit'", step_id: id, step_type: type, field: 'unit')
        elsif !%w[minutes hours days].include?(cfg['unit'])
          add_error("Node '#{id}' (wait) has invalid unit '#{cfg['unit']}' (must be minutes/hours/days)", step_id: id, step_type: type, field: 'unit')
        end
      when 'wait_for_reply'
        add_error("Node '#{id}' (wait_for_reply) requires 'timeout_hours'", step_id: id, step_type: type, field: 'timeout_hours') if cfg['timeout_hours'].blank?
        add_error("Node '#{id}' (wait_for_reply) requires 'on_reply_branch'", step_id: id, step_type: type, field: 'on_reply_branch') if cfg['on_reply_branch'].blank?
        add_error("Node '#{id}' (wait_for_reply) requires 'on_timeout_branch'", step_id: id, step_type: type, field: 'on_timeout_branch') if cfg['on_timeout_branch'].blank?
      when 'branch'
        add_error("Node '#{id}' (branch) requires 'condition'", step_id: id, step_type: type, field: 'condition') if cfg['condition'].blank?
        add_error("Node '#{id}' (branch) requires 'on_true_branch'", step_id: id, step_type: type, field: 'on_true_branch') if cfg['on_true_branch'].blank?
        add_error("Node '#{id}' (branch) requires 'on_false_branch'", step_id: id, step_type: type, field: 'on_false_branch') if cfg['on_false_branch'].blank?
      when 'require_approval'
        add_error("Node '#{id}' (require_approval) requires 'approver_user_id'", step_id: id, step_type: type, field: 'approver_user_id') if cfg['approver_user_id'].blank?
        add_error("Node '#{id}' (require_approval) requires 'on_approved_branch'", step_id: id, step_type: type, field: 'on_approved_branch') if cfg['on_approved_branch'].blank?
        add_error("Node '#{id}' (require_approval) requires 'on_rejected_branch'", step_id: id, step_type: type, field: 'on_rejected_branch') if cfg['on_rejected_branch'].blank?
      when 'enroll_in_nurture'
        if cfg['nurture_sequence_id'].blank?
          add_error("Node '#{id}' (enroll_in_nurture) requires 'nurture_sequence_id'", step_id: id, step_type: type, field: 'nurture_sequence_id')
        end
      when 'halt_nurture'
        # nurture_sequence_id optional (nil halts all for entity)
      when 'assign_owner'
        if cfg['strategy'].blank?
          add_error("Node '#{id}' (assign_owner) requires 'strategy'", step_id: id, step_type: type, field: 'strategy')
        # 'round_robin_list' was missing from this list, so the one strategy
        # backed by a real cursor (RoundRobinAssignmentList) failed validation
        # and could never be saved from the UI — leaving 'round_robin' as the
        # only reachable option even though it does not rotate on a cursor.
        elsif !%w[specific_user round_robin round_robin_list load_balanced].include?(cfg['strategy'])
          add_error("Node '#{id}' (assign_owner) has invalid strategy '#{cfg['strategy']}'", step_id: id, step_type: type, field: 'strategy')
        elsif cfg['strategy'] == 'specific_user' && cfg['user_id'].blank?
          add_error("Node '#{id}' (assign_owner) specific_user requires 'user_id'", step_id: id, step_type: type, field: 'user_id')
        elsif cfg['strategy'] == 'round_robin_list' && cfg['round_robin_list_id'].blank?
          add_error("Node '#{id}' (assign_owner) round_robin_list requires 'round_robin_list_id'", step_id: id, step_type: type, field: 'round_robin_list_id')
        end
      when 'add_tag'
        if !cfg['tag_names'].is_a?(Array) || cfg['tag_names'].empty?
          add_error("Node '#{id}' (add_tag) requires non-empty 'tag_names' Array", step_id: id, step_type: type, field: 'tag_names')
        end
      when 'remove_tag'
        if !cfg['tag_names'].is_a?(Array) || cfg['tag_names'].empty?
          add_error("Node '#{id}' (remove_tag) requires non-empty 'tag_names' Array", step_id: id, step_type: type, field: 'tag_names')
        end
      when 'score_entity'
        add_error("Node '#{id}' (score_entity) requires 'score_field'", step_id: id, step_type: type, field: 'score_field') if cfg['score_field'].blank?
        add_error("Node '#{id}' (score_entity) requires 'prompt'", step_id: id, step_type: type, field: 'prompt') if cfg['prompt'].blank?
      when 'classify_reply'
        if !cfg['categories'].is_a?(Array) || cfg['categories'].empty?
          add_error("Node '#{id}' (classify_reply) requires non-empty 'categories' Array", step_id: id, step_type: type, field: 'categories')
        end
        if cfg['write_to_variable'].blank?
          add_error("Node '#{id}' (classify_reply) requires 'write_to_variable'", step_id: id, step_type: type, field: 'write_to_variable')
        end
      when 'call_webhook'
        add_error("Node '#{id}' (call_webhook) requires 'url'", step_id: id, step_type: type, field: 'url') if cfg['url'].blank?
        if cfg['method'].present? && !%w[GET POST PUT PATCH DELETE].include?(cfg['method'].to_s.upcase)
          add_error("Node '#{id}' (call_webhook) has invalid method '#{cfg['method']}'", step_id: id, step_type: type, field: 'method')
        end
      end
    end
  end

  def validate_no_orphan_nodes
    ids = nodes.map { |n| n['id'] }
    dups = ids.group_by { |i| i }.select { |_, v| v.size > 1 }.keys
    dups.each { |d| add_error("Duplicate node id '#{d}'", step_id: d, field: 'id') }
    id_set = ids.to_set
    edges.each_with_index do |edge, idx|
      unless edge.is_a?(Hash)
        add_error("Edge at index #{idx} is not a Hash", step_type: 'edge')
        next
      end
      src = edge['source'] || edge['from']
      tgt = edge['target'] || edge['to']
      unless id_set.include?(src)
        add_error("Edge #{idx} source '#{src}' references unknown node", step_type: 'edge', field: 'source')
      end
      unless id_set.include?(tgt)
        add_error("Edge #{idx} target '#{tgt}' references unknown node", step_type: 'edge', field: 'target')
      end
    end
  end

  def validate_reachability
    return if nodes.empty?
    start_id = nodes.first['id']
    adjacency = Hash.new { |h, k| h[k] = [] }
    edges.each do |edge|
      next unless edge.is_a?(Hash)
      src = edge['source'] || edge['from']
      tgt = edge['target'] || edge['to']
      adjacency[src] << tgt if src && tgt
    end
    visited = Set.new
    queue = [start_id]
    until queue.empty?
      n = queue.shift
      next if visited.include?(n)
      visited << n
      adjacency[n].each { |child| queue << child unless visited.include?(child) }
    end
    nodes.each do |node|
      unless visited.include?(node['id'])
        @warnings << "Node '#{node['id']}' is not reachable from the entry node"
      end
    end
  end
end
