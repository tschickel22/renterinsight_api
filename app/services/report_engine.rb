class ReportEngine
  MAX_PER_PAGE = 500

  MODULE_DEFINITIONS = [
    { key: "leads",           model: "Lead",          category: "crm" },
    { key: "contacts",        model: "Contact",       category: "crm" },
    { key: "accounts",        model: "Account",       category: "crm" },
    { key: "deals",           model: "Deal",          category: "crm" },
    { key: "invoices",        model: "Invoice",       category: "finance" },
    { key: "payments",        model: "Payment",       category: "finance" },
    { key: "parts",           model: "Part",          category: "inventory" },
    { key: "service_tickets", model: "ServiceTicket", category: "operations" },
    { key: "warranty_claims", model: "WarrantyClaim", category: "operations" },
    { key: "units",           model: "Unit",          category: "inventory" },
    { key: "properties",      model: "Property",      category: "inventory" },
    { key: "vehicles",        model: "Vehicle",       category: "inventory" }
  ].freeze

  # { "leads" => Lead, ... } — silently drops modules whose model class
  # doesn't exist in this codebase.
  def self.available_modules
    @available_modules ||= MODULE_DEFINITIONS.each_with_object({}) do |entry, h|
      begin
        h[entry[:key]] = entry[:model].constantize
      rescue NameError
        next
      end
    end
  end

  def self.modules_list
    available_modules.map do |key, klass|
      defn  = MODULE_DEFINITIONS.find { |m| m[:key] == key }
      label = klass.respond_to?(:reportable_config) ? klass.reportable_config[:label] : klass.name.pluralize
      { key: key, label: label, category: defn[:category] }
    end
  end

  # Returns field definitions for a module, merging in any company custom fields.
  # custom_field_keys are prefixed with "cf_" to distinguish them from standard columns.
  def self.field_definitions(module_key, company_id = nil)
    klass = available_modules[module_key.to_s]
    return [] unless klass && klass.respond_to?(:reportable_config)

    standard = klass.reportable_config[:fields].dup

    # Merge custom fields when company_id is provided and model has the JSONB column
    if company_id.present? && klass.column_names.include?("custom_field_values")
      custom = CustomField
        .active
        .for_module(module_key.to_s)
        .where(company_id: company_id)
        .ordered
        .map do |cf|
          {
            key:        "cf_#{cf.field_key}",
            label:      cf.name,
            type:       map_custom_field_type(cf.field_type),
            filterable: true,
            sortable:   false,
            custom:     true
          }
        end
      standard + custom
    else
      standard
    end
  end

  def self.run(params)
    params      = (params || {}).with_indifferent_access
    klass       = available_modules[params[:module].to_s]
    raise ArgumentError, "Unknown report module: #{params[:module]}" unless klass
    raise ArgumentError, "Module #{params[:module]} is not reportable" unless klass.include?(Reportable)

    company_id  = params[:company_id]
    location_id = params[:location_id]
    all_fields  = Array(params[:fields]).map(&:to_s)

    # filters is already a plain Hash (controller converts ActionController::Parameters)
    filters = (params[:filters] || {}).with_indifferent_access
    filters[:location_id] ||= location_id if location_id.present?

    sort_by    = params[:sort_by].to_s
    sort_order = params[:sort_order].to_s.downcase == "desc" ? "DESC" : "ASC"
    page       = [params[:page].to_i, 1].max
    per_page   = params[:per_page].to_i
    per_page   = 50  if per_page <= 0
    per_page   = MAX_PER_PAGE if per_page > MAX_PER_PAGE

    # Separate standard vs custom (cf_-prefixed) fields
    standard_fields = all_fields.reject { |f| f.start_with?("cf_") }
    custom_fields   = all_fields.select { |f| f.start_with?("cf_") }

    scope = klass.all
    scope = scope.where(company_id: company_id) if company_id.present? && klass.column_names.include?("company_id")
    scope = klass.apply_report_filters(scope, filters)

    total       = scope.count
    total_pages = (total.to_f / per_page).ceil

    # Sort — only supported on standard sortable columns
    allowed_standard = klass.reportable_config[:fields].map { |f| f[:key].to_s }
    if allowed_standard.include?(sort_by) && klass.column_names.include?(sort_by)
      scope = scope.order(Arel.sql("#{klass.quoted_table_name}.#{klass.connection.quote_column_name(sort_by)} #{sort_order}"))
    end

    # Build SELECT covering both standard columns and JSONB-extracted custom fields
    select_sql = build_select(klass, standard_fields, custom_fields)
    scope      = scope.select(Arel.sql(select_sql))
    scope      = scope.offset((page - 1) * per_page).limit(per_page)

    # Resolve final ordered key list
    column_keys = resolve_column_keys(klass, standard_fields, custom_fields)

    # Build column metadata from standard + custom field definitions
    std_defs = klass.reportable_config[:fields]
    cf_defs  = company_id.present? && klass.column_names.include?("custom_field_values") ?
      CustomField.active.for_module(params[:module].to_s).where(company_id: company_id).map { |cf|
        { key: "cf_#{cf.field_key}", label: cf.name, type: map_custom_field_type(cf.field_type) }
      } : []

    all_defs = std_defs.map { |f| { key: f[:key].to_s, label: f[:label], type: f[:type].to_s } } + cf_defs

    columns = column_keys.map do |k|
      fd = all_defs.find { |f| f[:key] == k }
      { key: k, label: fd ? fd[:label] : k.humanize, type: fd ? fd[:type] : "string" }
    end

    # Rows as hashes keyed by column key (frontend expects Record<string, any>[])
    rows = scope.map do |rec|
      column_keys.each_with_object({}) { |k, h| h[k] = rec[k] }
    end

    {
      columns: columns,
      rows:    rows,
      meta: {
        total:       total,
        page:        page,
        per_page:    per_page,
        total_pages: total_pages
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  def self.build_select(klass, standard_fields, custom_fields)
    allowed = klass.reportable_config[:fields].map { |f| f[:key].to_s }
    std_keys = standard_fields.select { |k| allowed.include?(k) && klass.column_names.include?(k) }
    std_keys.unshift("id") unless std_keys.include?("id")

    parts = std_keys.map do |k|
      "#{klass.quoted_table_name}.#{klass.connection.quote_column_name(k)}"
    end

    # JSONB extraction for custom fields: custom_field_values->>'key' AS "cf_key"
    if custom_fields.any? && klass.column_names.include?("custom_field_values")
      custom_fields.each do |cf_key|
        field_key = cf_key.sub(/^cf_/, "")
        parts << "#{klass.quoted_table_name}.custom_field_values->>'#{field_key}' AS #{klass.connection.quote_column_name(cf_key)}"
      end
    end

    parts.join(", ")
  end

  def self.resolve_column_keys(klass, standard_fields, custom_fields)
    allowed = klass.reportable_config[:fields].map { |f| f[:key].to_s }
    std_keys = standard_fields.select { |k| allowed.include?(k) && klass.column_names.include?(k) }
    std_keys.unshift("id") unless std_keys.include?("id")

    cf_keys = klass.column_names.include?("custom_field_values") ? custom_fields : []
    std_keys + cf_keys
  end

  # Maps CustomField.field_type to the ReportFieldType enum the frontend understands
  def self.map_custom_field_type(field_type)
    case field_type.to_s
    when "number", "currency", "percent" then "number"
    when "date", "datetime"             then "date"
    when "checkbox"                     then "boolean"
    when "select", "multiselect"        then "enum"
    else                                     "string"
    end
  end
end
