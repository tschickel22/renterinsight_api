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
        row = { group.to_s => r['group_value'] }
        aggregates.each { |a| row[a[:key]] = round(r[a[:key]], a[:fn]) }
        row
      end
      if period
        rows = fill_empty_periods(rows, group, period, aggregates) if total_groups <= MAX_GROUPS && in_period_order?(aggregates)
        total_groups = [total_groups, rows.size].max
        rows.each { |row| row[group] = period_label(row[group].to_date, period) if row[group].respond_to?(:to_date) }
      end
      # Names instead of ids for people, accounts and contacts.
      @klass.resolve_references!(rows, [@defs[group]].compact) unless period
      rows.each { |row| row[group] = '(none)' if row[group].nil? }

      {
        # A period label or a resolved name is text, whatever the column holds.
        columns: [{ key: group, label: group_label(group, period),
                    type: period || @defs[group][:resolve_as] ? 'string' : @defs[group][:type].to_s }] +
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

    # Listed in date order (the default for a period, or sorted by the group).
    def in_period_order?(aggregates)
      sort = @params[:sort_by].to_s
      aggregates.none? { |a| a[:key] == sort }
    end

    # A month with nothing in it is still a month: without it the table skips
    # it and a line chart slopes straight across, reading as if it had values.
    # Counts and sums read 0; an average, minimum or maximum has none.
    def fill_empty_periods(rows, group, period, aggregates)
      dated = rows.select { |r| r[group].respond_to?(:to_date) }
      return rows if dated.size < 2

      by_date = dated.index_by { |r| r[group].to_date }
      first, last = by_date.keys.minmax
      step = { 'day' => 1.day, 'week' => 1.week, 'month' => 1.month, 'quarter' => 3.months, 'year' => 1.year }[period]
      all = []
      d = first
      while d <= last
        all << d
        return rows if all.size > MAX_GROUPS

        d += step
      end
      filled = all.map do |date|
        by_date[date] || aggregates.each_with_object({ group => date }) do |a, row|
          row[a[:key]] = %w[count sum].include?(a[:fn]) ? 0 : nil
        end
      end
      filled.reverse! if dated.first[group].to_date > dated.last[group].to_date
      filled + (rows - dated) # the (none) group stays last
    end

    def group_label(field, period)
      label = @defs[field][:label]
      period ? "#{label} (#{period})" : label
    end

    # 2026-01 for a month, 2026-Q1, 2026, "Week of 2026-01-05", or the day.
    # Sorts the same as the date, so a chart's axis stays in order.
    def period_label(date, period)
      case period
      when 'month' then date.strftime('%Y-%m')
      when 'quarter' then "#{date.year}-Q#{((date.month - 1) / 3) + 1}"
      when 'year' then date.year.to_s
      when 'week' then "Week of #{date.iso8601}"
      else date.iso8601
      end
    end

    def round(value, fn)
      # A total of nothing is 0 (deals with no price entered); an average,
      # minimum or maximum of nothing has no value.
      return (fn == 'sum' ? 0 : nil) if value.nil?
      return value.to_i if fn == 'count'

      value.to_d.round(2).to_f
    end
  end
end
