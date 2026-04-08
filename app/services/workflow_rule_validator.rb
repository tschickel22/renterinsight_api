# frozen_string_literal: true

class WorkflowRuleValidator
  KNOWN_EVENT_TYPES = %w[
    lead.created lead.updated lead.deleted lead.status_changed
    deal.created deal.updated deal.deleted deal.status_changed
    contact.created contact.updated contact.deleted contact.status_changed
    account.created account.updated account.deleted account.status_changed
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

  attr_reader :errors, :warnings

  def initialize(rule)
    @rule = rule
    @errors = []
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
      @errors << "Trigger must be a Hash"
      return
    end
    if trig['event_type'].blank?
      @errors << "Trigger must have an 'event_type'"
      return
    end
    unless KNOWN_EVENT_TYPES.include?(trig['event_type'])
      @warnings << "Trigger event_type '#{trig['event_type']}' is not in the known event list"
    end
  end

  def validate_steps_structure
    s = @rule.steps
    unless s.is_a?(Hash)
      @errors << "Steps must be a Hash with 'nodes' and 'edges'"
      return
    end
    unless s['nodes'].is_a?(Array)
      @errors << "Steps 'nodes' must be an Array"
    end
    unless s['edges'].is_a?(Array)
      @errors << "Steps 'edges' must be an Array"
    end
  end

  def validate_step_types
    nodes.each do |node|
      unless node.is_a?(Hash) && node['id'].present?
        @errors << "Each node must be a Hash with an 'id'"
        next
      end
      type = node['type']
      if type.blank?
        @errors << "Node '#{node['id']}' is missing a 'type'"
      elsif !VALID_STEP_TYPES.include?(type)
        @errors << "Node '#{node['id']}' has invalid step type '#{type}'"
      end
    end
  end

  def validate_step_configs
    nodes.each do |node|
      next unless node.is_a?(Hash)
      cfg = node['config'] || node['data'] || {}
      cfg = {} unless cfg.is_a?(Hash)
      id = node['id']
      case node['type']
      when 'send_email'
        %w[to subject body].each do |k|
          @errors << "Node '#{id}' (send_email) is missing required config '#{k}'" if cfg[k].blank?
        end
      when 'send_sms'
        %w[to body].each do |k|
          @errors << "Node '#{id}' (send_sms) is missing required config '#{k}'" if cfg[k].blank?
        end
      when 'update_field'
        if !cfg['fields'].is_a?(Hash) || cfg['fields'].empty?
          @errors << "Node '#{id}' (update_field) requires a non-empty 'fields' Hash"
        end
      when 'create_activity'
        %w[activity_type subject].each do |k|
          @errors << "Node '#{id}' (create_activity) is missing required config '#{k}'" if cfg[k].blank?
        end
      when 'wait'
        @errors << "Node '#{id}' (wait) requires 'duration'" if cfg['duration'].blank?
        if cfg['unit'].blank?
          @errors << "Node '#{id}' (wait) requires 'unit'"
        elsif !%w[minutes hours days].include?(cfg['unit'])
          @errors << "Node '#{id}' (wait) has invalid unit '#{cfg['unit']}' (must be minutes/hours/days)"
        end
      when 'wait_for_reply'
        @errors << "Node '#{id}' (wait_for_reply) requires 'timeout_hours'" if cfg['timeout_hours'].blank?
        @errors << "Node '#{id}' (wait_for_reply) requires 'on_reply_branch'" if cfg['on_reply_branch'].blank?
        @errors << "Node '#{id}' (wait_for_reply) requires 'on_timeout_branch'" if cfg['on_timeout_branch'].blank?
      when 'branch'
        @errors << "Node '#{id}' (branch) requires 'condition'" if cfg['condition'].blank?
        @errors << "Node '#{id}' (branch) requires 'on_true_branch'" if cfg['on_true_branch'].blank?
        @errors << "Node '#{id}' (branch) requires 'on_false_branch'" if cfg['on_false_branch'].blank?
      when 'require_approval'
        @errors << "Node '#{id}' (require_approval) requires 'approver_user_id'" if cfg['approver_user_id'].blank?
        @errors << "Node '#{id}' (require_approval) requires 'on_approved_branch'" if cfg['on_approved_branch'].blank?
        @errors << "Node '#{id}' (require_approval) requires 'on_rejected_branch'" if cfg['on_rejected_branch'].blank?
      when 'enroll_in_nurture'
        @errors << "Node '#{id}' (enroll_in_nurture) requires 'nurture_sequence_id'" if cfg['nurture_sequence_id'].blank?
      when 'halt_nurture'
        # nurture_sequence_id optional (nil halts all for entity)
      when 'assign_owner'
        if cfg['strategy'].blank?
          @errors << "Node '#{id}' (assign_owner) requires 'strategy'"
        elsif !%w[specific_user round_robin load_balanced].include?(cfg['strategy'])
          @errors << "Node '#{id}' (assign_owner) has invalid strategy '#{cfg['strategy']}'"
        elsif cfg['strategy'] == 'specific_user' && cfg['user_id'].blank?
          @errors << "Node '#{id}' (assign_owner) specific_user requires 'user_id'"
        end
      when 'add_tag'
        if !cfg['tag_names'].is_a?(Array) || cfg['tag_names'].empty?
          @errors << "Node '#{id}' (add_tag) requires non-empty 'tag_names' Array"
        end
      when 'remove_tag'
        if !cfg['tag_names'].is_a?(Array) || cfg['tag_names'].empty?
          @errors << "Node '#{id}' (remove_tag) requires non-empty 'tag_names' Array"
        end
      when 'score_entity'
        @errors << "Node '#{id}' (score_entity) requires 'score_field'" if cfg['score_field'].blank?
        @errors << "Node '#{id}' (score_entity) requires 'prompt'" if cfg['prompt'].blank?
      when 'classify_reply'
        if !cfg['categories'].is_a?(Array) || cfg['categories'].empty?
          @errors << "Node '#{id}' (classify_reply) requires non-empty 'categories' Array"
        end
        @errors << "Node '#{id}' (classify_reply) requires 'write_to_variable'" if cfg['write_to_variable'].blank?
      when 'call_webhook'
        @errors << "Node '#{id}' (call_webhook) requires 'url'" if cfg['url'].blank?
        if cfg['method'].present? && !%w[GET POST PUT PATCH DELETE].include?(cfg['method'].to_s.upcase)
          @errors << "Node '#{id}' (call_webhook) has invalid method '#{cfg['method']}'"
        end
      end
    end
  end

  def validate_no_orphan_nodes
    ids = nodes.map { |n| n['id'] }
    dups = ids.group_by { |i| i }.select { |_, v| v.size > 1 }.keys
    dups.each { |d| @errors << "Duplicate node id '#{d}'" }
    id_set = ids.to_set
    edges.each_with_index do |edge, idx|
      unless edge.is_a?(Hash)
        @errors << "Edge at index #{idx} is not a Hash"
        next
      end
      src = edge['source'] || edge['from']
      tgt = edge['target'] || edge['to']
      @errors << "Edge #{idx} source '#{src}' references unknown node" unless id_set.include?(src)
      @errors << "Edge #{idx} target '#{tgt}' references unknown node" unless id_set.include?(tgt)
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
