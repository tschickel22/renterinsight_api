# frozen_string_literal: true

class WorkflowPreviewService
  ENTITY_MAP = {
    'lead'           => 'Lead',
    'deal'           => 'Deal',
    'contact'        => 'Contact',
    'service_ticket' => 'ServiceTicket',
    'account'        => 'Account'
  }.freeze

  SAMPLE_LIMIT_CAP = 10
  COUNT_CAP        = 10_000

  def self.preview(rule, company:, sample_limit: SAMPLE_LIMIT_CAP)
    new(rule, company: company, sample_limit: sample_limit).preview
  end

  def initialize(rule, company:, sample_limit: SAMPLE_LIMIT_CAP)
    @rule    = rule
    @company = company
    @sample_limit = [sample_limit.to_i, SAMPLE_LIMIT_CAP].min
  end

  def preview
    klass = resolve_entity_class
    return error_result("Unknown entity_type: #{@rule.entity_type}") unless klass

    base_scope  = build_base_scope(klass)
    total_count = base_scope.limit(COUNT_CAP).count

    candidates  = apply_trigger_filter(base_scope)
    matched     = filter_by_conditions(candidates)

    matched_count    = matched.limit(COUNT_CAP).count
    sample_entities  = build_samples(matched, klass)
    action_sims      = simulate_actions(matched_count)
    warnings         = collect_warnings(matched_count)

    {
      matched_count:      matched_count,
      total_count:        total_count,
      sample_entities:    sample_entities,
      action_simulations: action_sims,
      warnings:           warnings
    }
  end

  private

  def resolve_entity_class
    class_name = ENTITY_MAP[@rule.entity_type.to_s.downcase]
    class_name&.safe_constantize
  end

  def build_base_scope(klass)
    scope = @company.public_send(collection_name(klass))
    if klass.column_names.include?('is_deleted')
      scope.where(is_deleted: [false, nil])
    else
      scope
    end
  end

  def collection_name(klass)
    klass.name.underscore.pluralize.to_sym
  end

  def apply_trigger_filter(scope)
    trigger = @rule.trigger || {}
    event   = trigger['event_type'].to_s

    if event.match?(/inactivity_(\d+)d/i)
      days = event.match(/inactivity_(\d+)d/i)[1].to_i
      scope.where('updated_at < ?', days.days.ago)
    else
      # For created / status_changed / updated — all current records are candidates
      scope
    end
  end

  def filter_by_conditions(scope)
    conditions = @rule.conditions
    return scope if conditions.blank?

    ids = scope.limit(COUNT_CAP).pluck(:id)
    return scope.none if ids.empty?

    matching_ids = []
    ids.each_slice(500) do |batch_ids|
      records = scope.where(id: batch_ids)
      records.each do |record|
        context = record.as_json
        if WorkflowEngine::ConditionEvaluator.evaluate(conditions, context)
          matching_ids << record.id
        end
      end
    end

    scope.where(id: matching_ids)
  end

  def build_samples(matched_scope, klass)
    records = matched_scope.limit(@sample_limit).to_a
    condition_fields = extract_condition_fields

    records.map do |record|
      attrs = {}
      condition_fields.each do |field|
        attrs[field] = record.try(field) if record.respond_to?(field)
      end
      {
        id:         record.id,
        label:      entity_label(record),
        attributes: attrs
      }
    end
  end

  def entity_label(record)
    if record.respond_to?(:full_name) && record.full_name.present?
      record.full_name
    elsif record.respond_to?(:name) && record.name.present?
      record.name
    elsif record.respond_to?(:email)
      record.email
    else
      "##{record.id}"
    end
  end

  def extract_condition_fields
    fields = []
    extract_fields_recursive(@rule.conditions, fields)
    fields.uniq
  end

  def extract_fields_recursive(node, fields)
    return if node.blank?

    case node
    when Array
      node.each { |n| extract_fields_recursive(n, fields) }
    when Hash
      if node['field'].present?
        fields << node['field'].to_s.split('.').last
      end
      (node['children'] || node['conditions'] || []).each { |c| extract_fields_recursive(c, fields) }
    end
  end

  # --------------- Action simulation (zero side effects) ---------------

  def simulate_actions(matched_count)
    steps = (@rule.steps || {})['nodes'] || []
    steps.filter_map do |step|
      type = step['type'].to_s
      config = step['config'] || {}
      sim = simulate_step(type, config, matched_count)
      sim if sim
    end
  end

  def simulate_step(type, config, count)
    case type
    when 'enroll_in_nurture'
      simulate_enroll_nurture(config, count)
    when 'assign_owner'
      simulate_assign_owner(config, count)
    when 'create_activity'
      simulate_create_activity(config, count)
    when 'update_field'
      simulate_update_field(config, count)
    when 'send_email'
      simulate_send_notification('email', config, count)
    when 'send_sms'
      simulate_send_notification('SMS', config, count)
    when 'add_tag'
      simulate_add_tag(config, count)
    when 'remove_tag'
      simulate_remove_tag(config, count)
    when 'create_deal'
      { type: type, summary: "Would create deal from each matched lead", target_count: count, warnings: [] }
    when 'score_entity', 'classify_reply'
      estimate = count * 0.003 # rough per-call estimate
      { type: type, summary: "Would call Anthropic API ~#{count} times (estimated cost: $#{'%.2f' % estimate})", target_count: count, warnings: [] }
    when 'call_webhook'
      url = config['url'].to_s.truncate(80)
      { type: type, summary: "Would send #{config['method'] || 'POST'} to #{url} for #{count} records", target_count: count, warnings: [] }
    when 'branch', 'wait', 'wait_for_reply', 'require_approval', 'halt_nurture'
      nil # control-flow nodes — not actionable previews
    else
      { type: type, summary: "Would execute '#{type}' on #{count} records", target_count: count, warnings: [] }
    end
  end

  def simulate_enroll_nurture(config, count)
    seq_id = config['nurture_sequence_id']
    seq = @company.nurture_sequences.find_by(id: seq_id) if seq_id
    warnings = []
    if seq
      summary = "Would enroll in nurture ##{seq.id} (#{seq.name})"
    else
      summary = "Would enroll in nurture ##{seq_id || '?'}"
      warnings << "Action references nurture_sequence_id #{seq_id || 'nil'} which does not exist"
    end
    { type: 'enroll_in_nurture', summary: summary, target_count: count, warnings: warnings }
  end

  def simulate_assign_owner(config, count)
    strategy = config['strategy'].to_s
    warnings = []
    case strategy
    when 'specific_user'
      user = @company.users.find_by(id: config['user_id'])
      summary = user ? "Would assign to #{user.try(:full_name) || user.try(:email) || "user ##{user.id}"}" : "Would assign to user ##{config['user_id']}"
      warnings << "Assigned user ##{config['user_id']} not found" unless user
    when 'round_robin', 'load_balanced'
      pool = @company.users
      if config['role_filter'].present?
        pool = pool.where(role: config['role_filter']) if pool.column_names.include?('role')
      end
      warnings << "Action assign_user #{strategy} but company has no active users" if pool.count.zero?
      summary = "Would assign via #{strategy} across #{pool.count} user(s)"
    else
      summary = "Would assign owner (strategy: #{strategy.presence || 'unspecified'})"
    end
    { type: 'assign_owner', summary: summary, target_count: count, warnings: warnings }
  end

  def simulate_create_activity(config, count)
    due_hours = config['due_in_hours'] || 24
    assignee = config['assigned_to'].to_s.presence || 'entity owner'
    summary = "Would create '#{config['activity_type']}' activity, due in #{due_hours}h, assigned to #{assignee}"
    { type: 'create_activity', summary: summary, target_count: count, warnings: [] }
  end

  def simulate_update_field(config, count)
    summary = "Would set #{config['field']} = #{config['value'].inspect} on #{count} records"
    { type: 'update_field', summary: summary, target_count: count, warnings: [] }
  end

  def simulate_send_notification(channel, config, count)
    recipient = config['to'].to_s.presence || 'entity'
    summary = "Would send #{channel} to #{recipient}"
    if config['subject'].present?
      summary += " with subject: #{config['subject'].to_s.truncate(60)}"
    end
    { type: "send_#{channel.downcase}", summary: summary, target_count: count, warnings: [] }
  end

  def simulate_add_tag(config, count)
    tag = config['tag_name'] || config['tag'] || '?'
    { type: 'add_tag', summary: "Would add tag '#{tag}' to #{count} records", target_count: count, warnings: [] }
  end

  def simulate_remove_tag(config, count)
    tag = config['tag_name'] || config['tag'] || '?'
    { type: 'remove_tag', summary: "Would remove tag '#{tag}' from #{count} records", target_count: count, warnings: [] }
  end

  # --------------- Warnings ---------------

  def collect_warnings(matched_count)
    warnings = []
    entity_label = @rule.entity_type.to_s.downcase

    if @rule.conditions.blank? || (@rule.conditions.is_a?(Hash) && @rule.conditions.empty?) || (@rule.conditions.is_a?(Array) && @rule.conditions.empty?)
      warnings << "Rule has no conditions — will fire on every #{entity_label}"
    end

    steps = (@rule.steps || {})['nodes'] || []
    steps.each do |step|
      config = step['config'] || {}
      case step['type']
      when 'enroll_in_nurture'
        seq_id = config['nurture_sequence_id']
        unless seq_id && @company.nurture_sequences.exists?(id: seq_id)
          warnings << "Action references nurture_sequence_id #{seq_id || 'nil'} which does not exist"
        end
      when 'assign_owner'
        if config['strategy'].to_s.in?(%w[round_robin load_balanced])
          pool = @company.users
          if config['role_filter'].present? && pool.respond_to?(:column_names) && pool.column_names.include?('role')
            pool = pool.where(role: config['role_filter'])
          end
          if pool.count.zero?
            warnings << "Action assign_user #{config['strategy']} but location has no active users"
          end
        end
      end
    end

    warnings.uniq
  end

  def error_result(message)
    {
      matched_count:      0,
      total_count:        0,
      sample_entities:    [],
      action_simulations: [],
      warnings:           [message]
    }
  end
end
