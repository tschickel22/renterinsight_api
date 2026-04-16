module Reportable
  extend ActiveSupport::Concern

  class_methods do
    # Override in including model. Returns:
    #   { label: "Leads", fields: [ { key:, label:, type:, filterable:, sortable: }, ... ] }
    def reportable_config
      { label: name.pluralize, fields: [] }
    end

    # Apply structured report filters to an ActiveRecord scope.
    # filters:
    #   date_range: { field:, from:, to: }
    #   where:      [{ field:, operator:, value: }, ...] (or single hash)
    #   location_id: Integer
    def apply_report_filters(scope, filters)
      filters = (filters || {}).with_indifferent_access
      allowed = reportable_config[:fields].map { |f| f[:key].to_s }

      if (loc = filters[:location_id]).present? && column_names.include?("location_id")
        scope = scope.where(location_id: loc)
      end

      if (dr = filters[:date_range]).present?
        field = dr[:field].to_s
        if allowed.include?(field) && column_names.include?(field)
          scope = scope.where("#{quoted_table_name}.#{connection.quote_column_name(field)} >= ?", dr[:from]) if dr[:from].present?
          scope = scope.where("#{quoted_table_name}.#{connection.quote_column_name(field)} <= ?", dr[:to])   if dr[:to].present?
        end
      end

      where_clauses = filters[:where]
      where_clauses = [where_clauses] if where_clauses.is_a?(Hash)
      Array(where_clauses).each do |clause|
        clause = clause.with_indifferent_access
        field    = clause[:field].to_s
        operator = clause[:operator].to_s.presence || "eq"
        value    = clause[:value]
        next unless allowed.include?(field) && column_names.include?(field)
        # Skip filters with blank values — prevents PG type-cast errors on
        # integer/bigint/date columns when the user hasn't filled in a value yet.
        next if value.nil? || value.to_s.strip.empty?

        col = "#{quoted_table_name}.#{connection.quote_column_name(field)}"
        case operator
        when "eq"       then scope = scope.where("#{col} = ?", value)
        when "contains" then scope = scope.where("#{col} ILIKE ?", "%#{value}%")
        when "gt"       then scope = scope.where("#{col} > ?", value)
        when "lt"       then scope = scope.where("#{col} < ?", value)
        when "in"
          # Support comma-separated string ("foo,bar") or already-split array
          values = value.is_a?(Array) ? value : value.to_s.split(",").map(&:strip).reject(&:empty?)
          scope = scope.where("#{col} IN (?)", values) if values.any?
        end
      end

      scope
    end

    # Build a SELECT clause from a list of field keys, restricted to declared
    # reportable fields that actually exist as columns. Always includes :id.
    def report_select(fields)
      allowed = reportable_config[:fields].map { |f| f[:key].to_s }
      keys    = Array(fields).map(&:to_s).select { |k| allowed.include?(k) && column_names.include?(k) }
      keys.unshift("id") unless keys.include?("id")
      keys.map { |k| "#{quoted_table_name}.#{connection.quote_column_name(k)}" }.join(", ")
    end
  end
end
