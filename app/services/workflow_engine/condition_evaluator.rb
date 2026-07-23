module WorkflowEngine
  module ConditionEvaluator
    module_function

    def evaluate(conditions, context)
      return true if conditions.blank?
      return true if conditions.is_a?(Array) && conditions.empty?
      return true if conditions.is_a?(Hash) && conditions.empty?
      evaluate_node(conditions, context)
    end

    def evaluate_node(node, context)
      case node
      when Array
        node.all? { |n| evaluate_node(n, context) }
      when Hash
        type = node['type'] || node['logic']
        children = node['children'] || node['conditions']
        if type == 'and'
          Array(children).all? { |c| evaluate_node(c, context) }
        elsif type == 'or'
          Array(children).any? { |c| evaluate_node(c, context) }
        else
          evaluate_leaf(node, context)
        end
      else
        true
      end
    end

    def evaluate_leaf(leaf, context)
      field_value = resolve_field(leaf['field'], context)
      value = leaf['value']
      case leaf['operator'].to_s
      when 'equals' then field_value == value
      when 'not_equals' then field_value != value
      when 'contains'
        # Case-insensitive to match the SQL ILIKE semantics used by Audiences::FilterCompiler
        # (the audience preview/count). Without this, enrollment silently matches fewer records
        # than the preview promised whenever case differs (e.g. "Champion" vs "champion").
        if field_value.is_a?(String) then field_value.downcase.include?(value.to_s.downcase)
        elsif field_value.is_a?(Array) then field_value.include?(value)
        else false
        end
      when 'not_contains'
        if field_value.is_a?(String) then !field_value.downcase.include?(value.to_s.downcase)
        elsif field_value.is_a?(Array) then !field_value.include?(value)
        else true
        end
      when 'starts_with' then field_value.to_s.downcase.start_with?(value.to_s.downcase)
      when 'ends_with' then field_value.to_s.downcase.end_with?(value.to_s.downcase)
      when 'greater_than' then field_value.to_f > value.to_f
      when 'less_than' then field_value.to_f < value.to_f
      when 'greater_than_or_equal' then field_value.to_f >= value.to_f
      when 'less_than_or_equal' then field_value.to_f <= value.to_f
      when 'is_set' then !field_value.nil? && field_value != ''
      when 'is_blank' then field_value.nil? || field_value == ''
      when 'in' then Array(value).include?(field_value)
      when 'not_in' then !Array(value).include?(field_value)
      when 'days_since_greater_than'
        begin
          (Date.current - Date.parse(field_value.to_s)).to_i > value.to_i
        rescue ArgumentError, TypeError
          false
        end
      when 'is_business_hours'
        t = Time.current
        (9..16).cover?(t.hour) && (1..5).cover?(t.wday)
      when 'matches_regex'
        Regexp.new(value.to_s).match?(field_value.to_s)
      when 'tags_include'
        evaluate_tags_include(field_value, value)
      when 'tags_exclude'
        !evaluate_tags_include(field_value, value)
      when 'tags_any_of'
        Array(value).any? { |v| evaluate_tags_include(field_value, v) }
      else
        false
      end
    rescue => e
      Rails.logger.error "[ConditionEvaluator] leaf error: #{e.message}"
      false
    end

    def evaluate_tags_include(field_value, value)
      return false if field_value.nil?
      tags = Array(field_value)
      tags.any? do |t|
        case t
        when String then t == value.to_s
        when Integer then t == value.to_i
        when Hash
          t['name'] == value.to_s || t['id'] == value.to_i ||
            t[:name] == value.to_s || t[:id] == value.to_i
        else
          (t.respond_to?(:name) && t.name == value.to_s) ||
            (t.respond_to?(:id) && t.id == value.to_i)
        end
      end
    end

    def resolve_field(path, context)
      return nil if path.blank?
      parts = path.to_s.split('.')
      current = context
      parts.each do |part|
        return nil if current.nil?
        current = step_into(current, part)
      end
      current
    end

    # One step of the path walk. Falls through to custom_field_values when the
    # segment isn't a real attribute — otherwise conditions comparing a custom
    # field (e.g. `entity.next_appointment` on Evangeline leads) always came
    # back nil and branches silently took the wrong path.
    def step_into(current, part)
      if current.is_a?(Hash)
        current[part] || current[part.to_sym]
      elsif %w[tags tag_names].include?(part.to_s) && current.respond_to?(:tags)
        # `tags` is a has_many association, so attribute_missing? routes it to the
        # custom-field fallback (returning nil) — which left the tags_include /
        # tags_exclude / tags_any_of operators unable to see a record's tags.
        # Resolve it to an array of tag names so those operators work (e.g. the
        # lead.tagged trigger with a "tags include 'hot-lead'" condition).
        current.tags.map { |t| t.respond_to?(:name) ? t.name : t }
      elsif current.respond_to?(part) && !attribute_missing?(current, part)
        current.public_send(part)
      elsif current.respond_to?(:custom_field_values)
        CustomFieldsAccess.read(current, part)
      end
    end

    # An AR model responds_to? every column, but we want the custom-field
    # fallback to fire when the segment is a JSONB key rather than a real
    # column. This picks the fallback when the AR model doesn't have the
    # attribute at all.
    def attribute_missing?(record, name)
      return false unless record.class.respond_to?(:column_names)
      !record.class.column_names.include?(name.to_s) &&
        !record.class.instance_methods(false).include?(name.to_sym)
    end
  end
end
