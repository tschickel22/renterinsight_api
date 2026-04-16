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
      parts.each do |part|
        return nil if current.nil?
        current = if current.is_a?(Hash)
                    current[part] || current[part.to_sym]
                  elsif current.respond_to?(part)
                    current.public_send(part)
                  else
                    nil
                  end
      end
      current
    end
  end
end
