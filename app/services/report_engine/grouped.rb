# frozen_string_literal: true

class ReportEngine
  # A report that groups rows and adds them up (E118): "deals by salesperson,
  # total selling price and average", "leads by month", "invoices by status".
  # The result has the same shape as a list report (columns, rows, meta), so
  # the report table, the CSV export and saved reports show it as they are.
  #
  # Group and aggregate clauses cannot take bind parameters the way filter
  # values do, so every field is checked against the module's reportable
  # fields and real columns and quoted with quote_column_name, and the
  # period and functions come from fixed lists. A key that fails a check is
  # refused, never passed through.
  #
  #   group_by:     a reportable column
  #   group_period: day | week | month | quarter | year (date columns only)
  #   aggregates:   up to 3 of { fn: count | sum | avg | min | max, field: a number column }
  #                 count needs no field. Default: count.
  #   sort_by:      the group column or an aggregate key ("sum_selling_price")
  class Grouped
    PERIODS = %w[day week month quarter year].freeze
    FUNCTIONS = %w[count sum avg min max].freeze
    FUNCTION_LABELS = { 'count' => 'Count', 'sum' => 'Total', 'avg' => 'Average', 'min' => 'Lowest', 'max' => 'Highest' }.freeze
    MAX_AGGREGATES = 3
    MAX_GROUPS = 200

    def initialize(klass, scope, params)
      @klass = klass
      @scope = scope
      @params = params
      @defs = klass.reportable_config[:fields].index_by { |f| f[:key].to_s }
    end

    def run
      group = group_field
      period = group_period(group)
      aggregates = aggregate_list
      group_expr = period ? "date_trunc('#{period}', #{column(group)})" : column(group)

      selects = [Arel.sql("#{group_expr} AS #{quote('group_value')}")] + aggregates.map { |a| Arel.sql("#{a[:sql]} AS #{quote(a[:key])}") }
      grouped = @scope.unscope(:order, :select).group(Arel.sql(group_expr))
      total_groups = grouped.count.size
      records = grouped.select(*selects).reorder(Arel.sql(order_clause(aggregates, period))).limit(MAX_GROUPS)

      rows = records.map do |r|
        value = r['group_value']
        value = value.to_date.iso8601 if period && value.respond_to?(:to_date)
        row = { group.to_s => value }
        aggregates.each { |a| row[a[:key]] = round(r[a[:key]], a[:fn]) }
        row
      end
      # Names instead of ids for people, accounts and contacts.
      @klass.resolve_references!(rows, [@defs[group]].compact) unless period
      rows.each { |row| row[group] = '(none)' if row[group].nil? }

      {
        columns: [{ key: group, label: group_label(group, period), type: period ? 'date' : @defs[group][:type].to_s }] +
                 aggregates.map { |a| { key: a[:key], label: a[:label], type: 'number' } },
        rows: rows,
        meta: { total: total_groups, page: 1, per_page: MAX_GROUPS, total_pages: 1, grouped: true,
                truncated: total_groups > MAX_GROUPS, group_by: group, group_period: period,
                aggregates: aggregates.map { |a| a.slice(:fn, :field, :key) } }
      }
    end

    private

    def quote(name)
      @klass.connection.quote_column_name(name)
    end

    def column(field)
      "#{@klass.quoted_table_name}.#{quote(field)}"
    end

    def usable?(field)
      @defs.key?(field) && @klass.column_names.include?(field)
    end

    def group_field
      field = @params[:group_by].to_s
      raise ArgumentError, "Cannot group by #{field}: it is not a field of this report." unless usable?(field)

      field
    end

    def group_period(field)
      period = @params[:group_period].to_s.presence
      return nil unless period
      raise ArgumentError, "Unknown period #{period}. Use #{PERIODS.join(', ')}." unless PERIODS.include?(period)
      raise ArgumentError, "Only a date field can be grouped by #{period}." unless @defs[field][:type].to_s == 'date'

      period
    end

    def aggregate_list
      raw = Array(@params[:aggregates].presence || @params[:aggregate].presence || [{ fn: 'count' }])
      raw = [raw] if raw.is_a?(Hash)
      list = raw.first(MAX_AGGREGATES).map { |a| aggregate(a.to_h.with_indifferent_access) }
      list.uniq { |a| a[:key] }
    end

    def aggregate(spec)
      fn = spec[:fn].to_s.presence || 'count'
      raise ArgumentError, "Unknown total #{fn}. Use #{FUNCTIONS.join(', ')}." unless FUNCTIONS.include?(fn)

      field = spec[:field].to_s.presence
      if fn == 'count' && field.nil?
        return { fn: fn, field: nil, key: 'count', label: 'Count', sql: 'COUNT(*)' }
      end
      raise ArgumentError, "#{FUNCTION_LABELS[fn]} needs a field." if field.nil?
      raise ArgumentError, "Cannot total #{field}: it is not a field of this report." unless usable?(field)
      if %w[sum avg].include?(fn) && @defs[field][:type].to_s != 'number'
        raise ArgumentError, "#{FUNCTION_LABELS[fn]} works on number fields; #{@defs[field][:label]} is not one."
      end

      { fn: fn, field: field, key: "#{fn}_#{field}", label: "#{FUNCTION_LABELS[fn]} #{@defs[field][:label]}",
        sql: "#{fn.upcase}(#{column(field)})" }
    end

    # Sorts by the group or one of the aggregates; a date grouped by period
    # reads best oldest first, anything else largest first.
    def order_clause(aggregates, period)
      sort = @params[:sort_by].to_s
      dir = @params[:sort_order].to_s.downcase == 'asc' ? 'ASC' : 'DESC'
      if (agg = aggregates.find { |a| a[:key] == sort })
        "#{quote(agg[:key])} #{dir} NULLS LAST"
      elsif sort == @params[:group_by].to_s
        "#{quote('group_value')} #{dir} NULLS LAST"
      elsif period
        "#{quote('group_value')} ASC NULLS LAST"
      else
        "#{quote(aggregates.first[:key])} DESC NULLS LAST"
      end
    end

    def group_label(field, period)
      label = @defs[field][:label]
      period ? "#{label} (#{period})" : label
    end

    def round(value, fn)
      return nil if value.nil?
      return value.to_i if fn == 'count'

      value.to_d.round(2).to_f
    end
  end
end
