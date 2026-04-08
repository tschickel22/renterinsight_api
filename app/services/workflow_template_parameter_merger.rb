module WorkflowTemplateParameterMerger
  PARAM_REGEX = /\{\{\s*params\.([^}\s]+)\s*\}\}/

  def self.merge(steps, params)
    deep_transform(steps, params.to_h.stringify_keys)
  end

  def self.deep_transform(obj, params)
    case obj
    when Hash
      obj.each_with_object({}) { |(k, v), h| h[k] = deep_transform(v, params) }
    when Array
      obj.map { |v| deep_transform(v, params) }
    when String
      obj.gsub(PARAM_REGEX) do
        key = Regexp.last_match(1)
        params.key?(key) ? params[key].to_s : Regexp.last_match(0)
      end
    else
      obj
    end
  end
end
