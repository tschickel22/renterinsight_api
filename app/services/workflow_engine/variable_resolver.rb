module WorkflowEngine
  module VariableResolver
    TEMPLATE_REGEX = /\{\{\s*([^}]+?)\s*\}\}/

    module_function

    def resolve(template_string, variables)
      return template_string unless template_string.is_a?(String)

      template_string.gsub(TEMPLATE_REGEX) do
        path = Regexp.last_match(1).strip
        value = resolve_path(path, variables)
        value.nil? ? '' : value.to_s
      end
    end

    def resolve_hash(hash, variables)
      hash.transform_values do |v|
        case v
        when String then resolve(v, variables)
        when Hash then resolve_hash(v, variables)
        else v
        end
      end
    end

    def resolve_path(path, variables)
      return Time.current.iso8601 if path == 'now()'
      return Date.current.iso8601 if path == 'today()'

      parts = path.split('.')
      current = variables
      value = nil
      parts.each_with_index do |part, i|
        return log_unresolved(path, i, parts) if current.nil?
        current = step_into(current, part)
        value = current
      end
      value
    end

    # One step of the walk. Falls through to `custom_field_values` when the
    # segment isn't a real AR attribute — so `{{entity.next_appointment}}` in a
    # send_email template resolves to the custom-field value instead of ''.
    def step_into(current, part)
      if current.is_a?(Hash)
        current[part] || current[part.to_sym]
      elsif current.respond_to?(part) && !attribute_missing?(current, part)
        current.public_send(part)
      elsif current.respond_to?(:custom_field_values)
        CustomFieldsAccess.read(current, part)
      end
    end

    def attribute_missing?(record, name)
      return false unless record.class.respond_to?(:column_names)
      !record.class.column_names.include?(name.to_s) &&
        !record.class.instance_methods(false).include?(name.to_sym)
    end

    # Emit a single-line warning when a template references a path that doesn't
    # exist in the variables hash. Silent nil→'' collapse was masking every
    # typo in workflow templates; the warning gives builders a breadcrumb
    # without changing the runtime behaviour (returns nil as before).
    def log_unresolved(path, index, parts)
      Rails.logger.warn "[VariableResolver] path '#{path}' unresolved at segment '#{parts[index]}' (index #{index})" if defined?(Rails)
      nil
    end
  end
end
