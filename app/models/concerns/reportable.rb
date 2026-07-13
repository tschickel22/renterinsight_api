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

    # Post-process a set of report rows: replace raw foreign-key IDs with
    # human-readable display strings for any field whose config includes
    # `resolve_as:`. Called by ReportEngine after rows are built.
    #
    # Field def example:
    #   { key: "owner_id", label: "Assigned To", type: "number", resolve_as: :user, ... }
    #
    # Batches one SELECT per referenced type across all rows on the page.
    # If a lookup fails (record deleted), the row keeps the raw ID and
    # renders as "#123" — better than showing nothing.
    #
    # Supported types: :user, :contact, :account, :deal, :lead, :source
    def resolve_references!(rows, field_defs = nil)
      field_defs ||= reportable_config[:fields]
      return rows if rows.blank?

      resolvable = field_defs.select { |f| f[:resolve_as] }
      return rows if resolvable.empty?

      # Group field keys by ref type so we batch-load once per type.
      by_type = resolvable.group_by { |f| f[:resolve_as].to_sym }
                          .transform_values { |defs| defs.map { |f| f[:key].to_s } }

      # Batch-load names per type.
      name_maps = by_type.each_with_object({}) do |(type, keys), h|
        ids = rows.flat_map { |r| keys.map { |k| r[k] } }.compact.uniq
        next if ids.empty?
        h[type] = REPORT_REF_LOADERS[type]&.call(ids) || {}
      end

      # Replace IDs with names in place.
      rows.each do |row|
        by_type.each do |type, keys|
          keys.each do |key|
            id = row[key]
            next if id.blank?
            name = name_maps.dig(type, id.to_i)
            row[key] = name if name.present?
          end
        end
      end

      rows
    end

    # Loaders build { id => display_name } hashes. Use raw SQL for the
    # concatenation so we don't instantiate ActiveRecord objects just to
    # pull two columns.
    REPORT_REF_LOADERS = {
      user: ->(ids) do
        ::User.where(id: ids)
              .pluck(:id, Arel.sql("COALESCE(NULLIF(TRIM(CONCAT_WS(' ', first_name, last_name)), ''), name, email)"))
              .to_h
      end,
      contact: ->(ids) do
        ::Contact.where(id: ids)
                 .pluck(:id, Arel.sql("COALESCE(NULLIF(TRIM(CONCAT_WS(' ', first_name, last_name)), ''), email)"))
                 .to_h
      end,
      account: ->(ids) do
        ::Account.where(id: ids).pluck(:id, :name).to_h
      end,
      deal: ->(ids) do
        ::Deal.where(id: ids)
              .pluck(:id, Arel.sql("COALESCE(name, deal_number, CONCAT('Deal #', id))"))
              .to_h
      end,
      lead: ->(ids) do
        ::Lead.where(id: ids)
              .pluck(:id, Arel.sql("COALESCE(NULLIF(TRIM(CONCAT_WS(' ', first_name, last_name)), ''), email)"))
              .to_h
      end,
      source: ->(ids) do
        # LeadSource is the canonical source model but a couple of tenants
        # still ship a bare `Source`. Support whichever is defined.
        klass = ::LeadSource rescue nil
        klass ||= (::Source rescue nil)
        return {} unless klass
        klass.where(id: ids).pluck(:id, :name).to_h
      end
    }.freeze
  end
end
