# frozen_string_literal: true

module ActivityTrackable
  extend ActiveSupport::Concern

  SENSITIVE_FIELDS = %w[
    password password_digest token api_key credit_card ssn
  ].freeze

  SENSITIVE_PATTERNS = /secret|encrypted/i

  # Fields that cause association conflicts or are internal-only
  EXCLUDED_FIELDS = %w[
    updated_at created_at
  ].freeze

  included do
    after_create_commit :log_create_activity,  unless: -> { skip_activity_tracking }
    after_update_commit :log_update_activity,  unless: -> { skip_activity_tracking }
    after_destroy_commit :log_destroy_activity, unless: -> { skip_activity_tracking }
  end

  # Override in each model
  def activity_display_name
    try(:name) || "Record ##{id}"
  end

  def activity_module_name
    'general'
  end

  def activity_account_id
    resolve_account_id
  end

  def activity_location_id
    try(:location_id)
  end

  private

  def log_create_activity
    log_activity(
      action: 'created',
      description: "Created #{self.class.name.titleize.downcase} #{activity_display_name}"
    )
  rescue => e
    Rails.logger.error("[ActivityTrackable] Failed to log create for #{self.class.name}##{id}: #{e.message}")
    Rails.logger.error("[ActivityTrackable] #{e.backtrace&.first(3)&.join("\n")}")
  end

  def log_update_activity
    changes = filtered_changes
    return if changes.empty?

    action = determine_update_action(changes)
    description = build_update_description(action, changes)

    # Format changes for human-readable storage
    formatted_changes = format_changes_for_storage(changes)

    log_activity(
      action: action,
      description: description,
      changes_made: formatted_changes
    )
  rescue => e
    Rails.logger.error("[ActivityTrackable] Failed to log update for #{self.class.name}##{id}: #{e.message}")
    Rails.logger.error("[ActivityTrackable] #{e.backtrace&.first(3)&.join("\n")}")
  end

  def log_destroy_activity
    log_activity(
      action: 'deleted',
      description: "Deleted #{self.class.name.titleize.downcase} #{activity_display_name}"
    )
  rescue => e
    Rails.logger.error("[ActivityTrackable] Failed to log destroy for #{self.class.name}##{id}: #{e.message}")
  end

  def log_activity(action:, description:, changes_made: {})
    company = try(:company)
    return unless company

    ActivityLog.create!(
      company: company,
      user: Current.user,
      trackable: self,
      account_id: activity_account_id,
      location_id: activity_location_id,
      action: action,
      module_name: activity_module_name,
      entity_type_label: self.class.name.titleize,
      description: description,
      changes_made: changes_made.deep_stringify_keys,
      metadata: {},
      ip_address: Current.try(:ip_address)
    )
  rescue => e
    Rails.logger.error("[ActivityTrackable] Failed to create activity log for #{self.class.name}##{id}: #{e.message}")
    Rails.logger.error("[ActivityTrackable] #{e.backtrace&.first(5)&.join("\n")}")
  end

  def filtered_changes
    saved_changes.except(*EXCLUDED_FIELDS).reject do |key, _|
      SENSITIVE_FIELDS.include?(key) ||
        key.match?(SENSITIVE_PATTERNS)
    end
  end

  # Convert complex values (hashes, arrays) into human-readable strings
  # so the frontend doesn't show "[object Object]"
  def format_changes_for_storage(changes)
    formatted = {}

    changes.each do |field, values|
      old_val, new_val = values

      if field == 'custom_field_values'
        # For custom fields, diff the individual keys that changed
        old_hash = old_val.is_a?(Hash) ? old_val : {}
        new_hash = new_val.is_a?(Hash) ? new_val : {}

        # Find keys that actually changed
        all_keys = (old_hash.keys + new_hash.keys).uniq
        all_keys.each do |cf_key|
          cf_old = old_hash[cf_key]
          cf_new = new_hash[cf_key]
          next if cf_old == cf_new

          readable_key = cf_key.to_s.humanize
          formatted["Custom: #{readable_key}"] = [
            format_single_value(cf_old),
            format_single_value(cf_new)
          ]
        end
      else
        formatted[field] = [
          format_single_value(old_val),
          format_single_value(new_val)
        ]
      end
    end

    formatted
  end

  def format_single_value(val)
    case val
    when nil
      nil
    when Hash
      # For file/image metadata stored as JSON
      if val['filename']
        val['filename']
      elsif val['url']
        val['url']
      else
        val.map { |k, v| "#{k}: #{v}" }.join(', ')
      end
    when Array
      if val.all? { |v| v.is_a?(Hash) && v['filename'] }
        # Array of file metadata
        val.map { |v| v['filename'] }.join(', ')
      else
        val.map(&:to_s).join(', ')
      end
    when TrueClass, FalseClass
      val ? 'Yes' : 'No'
    else
      val.to_s
    end
  end

  def determine_update_action(changes)
    if changes.key?('is_deleted') && changes['is_deleted'].last == true
      'deleted'
    elsif changes.key?('status') || changes.key?('stage')
      'status_changed'
    else
      'updated'
    end
  end

  def build_update_description(action, changes)
    name = activity_display_name
    label = self.class.name.titleize.downcase

    case action
    when 'deleted'
      "Deleted #{label} #{name}"
    when 'status_changed'
      if changes.key?('status')
        old_val, new_val = changes['status']
        "#{label.capitalize} #{name} status changed from #{old_val || 'none'} to #{new_val}"
      elsif changes.key?('stage')
        old_val, new_val = changes['stage']
        "#{label.capitalize} #{name} stage changed from #{old_val || 'none'} to #{new_val}"
      else
        "Updated #{label} #{name}"
      end
    else
      changed_fields = changes.keys
        .reject { |k| k == 'custom_field_values' }
        .map(&:humanize)

      # Add custom field names if custom_field_values changed
      if changes.key?('custom_field_values')
        old_hash = changes['custom_field_values'][0].is_a?(Hash) ? changes['custom_field_values'][0] : {}
        new_hash = changes['custom_field_values'][1].is_a?(Hash) ? changes['custom_field_values'][1] : {}
        cf_changed = (old_hash.keys + new_hash.keys).uniq.select { |k| old_hash[k] != new_hash[k] }
        changed_fields += cf_changed.map { |k| k.to_s.humanize }
      end

      if changed_fields.any?
        "Updated #{label} #{name}: #{changed_fields.join(', ')}"
      else
        "Updated #{label} #{name}"
      end
    end
  end

  def resolve_account_id
    case self.class.name
    when 'Account'
      id
    when 'Contact', 'Deal', 'ServiceTicket'
      try(:account_id)
    when 'Lead'
      try(:converted_account_id)
    when 'Quote'
      try(:account_id) || try(:deal)&.try(:account_id)
    when 'Invoice'
      try(:account_id) || try(:deal)&.try(:account_id) || try(:lease)&.try(:property)&.try(:account_id)
    when 'Communication'
      try(:communicable)&.try(:account_id)
    else
      try(:account_id)
    end
  end
end
