module Audiences
  # Compiles a filter_tree into an ActiveRecord scope using SQL.
  # Mirrors the operator semantics of WorkflowEngine::ConditionEvaluator but emits
  # WHERE clauses instead of evaluating in Ruby — orders of magnitude faster on
  # 10k+ row audiences.
  #
  # Hardcoded source types: Lead, Contact, Account.
  class FilterCompiler
    class CompilationError < StandardError; end

    SUPPORTED_OPERATORS = %w[
      equals not_equals contains not_contains starts_with ends_with
      greater_than less_than greater_than_or_equal less_than_or_equal
      is_set is_blank in not_in days_since_greater_than
      tags_include tags_exclude tags_any_of
    ].freeze

    VIRTUAL_FIELDS = %w[source_name owner_name].freeze

    ADDRESS_COLUMNS = {
      'Lead'    => %w[city state zip],
      'Contact' => %w[street city state zip],
      'Account' => %w[billing_street billing_city billing_state billing_postal_code
                      shipping_street shipping_city shipping_state shipping_postal_code]
    }.freeze

    # Typed by people and imported from spreadsheets, so "co", "CO" and "CO "
    # all mean Colorado. Exact comparisons on these ignore case and
    # surrounding spaces.
    CASE_INSENSITIVE_FIELDS = ADDRESS_COLUMNS.values.flatten.uniq.freeze

    def initialize(company:, source_type:, filter_tree:,
                   exclude_filter_tree: nil,
                   manual_include_ids: nil,
                   manual_exclude_ids: nil,
                   exclude_active_campaign_enrollees: false,
                   exclude_active_nurture_enrollees: false,
                   own_campaign_id: nil,
                   channel: 'email',
                   sms_consent_acknowledged: false)
      @company = company
      @source_type = source_type
      # 'email', 'sms', or 'mixed' for a campaign whose steps both email and text.
      @channel = channel.to_s.presence || 'email'
      @sms_consent_acknowledged = ActiveModel::Type::Boolean.new.cast(sms_consent_acknowledged)
      @filter_tree = filter_tree.is_a?(Hash) ? filter_tree.deep_stringify_keys : {}
      @exclude_filter_tree = exclude_filter_tree.is_a?(Hash) ? exclude_filter_tree.deep_stringify_keys : nil
      @manual_include_ids = Array(manual_include_ids).map(&:to_i).reject(&:zero?)
      @manual_exclude_ids = Array(manual_exclude_ids).map(&:to_i).reject(&:zero?)
      @exclude_active_campaign_enrollees = ActiveModel::Type::Boolean.new.cast(exclude_active_campaign_enrollees)
      @exclude_active_nurture_enrollees = ActiveModel::Type::Boolean.new.cast(exclude_active_nurture_enrollees)
      # The campaign this audience belongs to. "Active in other campaigns" must not
      # count its own enrollments, or once it starts every recipient it is sending
      # to drops out of its own audience (campaign 42's members list fell to 33).
      @own_campaign_id = own_campaign_id
    end

    def scope
      base = base_relation
      base = apply_node(base, @filter_tree) if @filter_tree.present?

      if @manual_include_ids.any?
        base = base.or(base_relation.where(id: @manual_include_ids))
      end

      if @exclude_filter_tree.present?
        excluded_ids_scope = apply_node(base_relation, @exclude_filter_tree).select(:id)
        base = base.where.not(id: excluded_ids_scope)
      end

      if @manual_exclude_ids.any?
        base = base.where.not(id: @manual_exclude_ids)
      end

      if @exclude_active_campaign_enrollees
        active_campaign_recipient_ids = CampaignEnrollment
          .where(status: %w[pending active])
          .where(recipient_type: @source_type)
        active_campaign_recipient_ids = active_campaign_recipient_ids.where.not(campaign_id: @own_campaign_id) if @own_campaign_id
        active_campaign_recipient_ids = active_campaign_recipient_ids.select(:recipient_id)
        base = base.where.not(id: active_campaign_recipient_ids)
      end

      if @exclude_active_nurture_enrollees
        active_nurture_ids = NurtureEnrollment
          .where(status: 'running')
          .where(enrollable_type: @source_type)
          .select(:enrollable_id)
        base = base.where.not(id: active_nurture_ids)
      end

      base = apply_email_reachability(base) if @channel == 'email'
      base = apply_any_channel_reachability(base) if @channel == 'mixed'

      base
    end

    def count
      scope.count
    end

    def sample(limit: 5)
      scope.limit(limit).map { |r| sample_row(r) }
    end

    private

    # Drops records an email campaign could never reach: no address at all, an address a
    # previous send proved dead, or one whose owner reported us as spam.
    #
    # This belongs in the compiler rather than in AudienceEnroller because the compiler is
    # what the audience screen counts and previews with. Filtering only at enrollment meant
    # the dealer was shown an estimate that included recipients the send would silently skip,
    # so the audience always looked larger than the campaign it produced. It also let a known
    # hard bounce back into every audience built afterwards, spending SES reputation to
    # rediscover what the last bounce already established.
    #
    # AudienceEnroller keeps its own per-record guards. Those are the backstop for an address
    # that goes bad between building an audience and sending to it.
    # A campaign that both emails and texts can reach someone on either. Keeping only
    # the emailable left out every lead with just a phone number, so its texts never
    # went to the people most likely to need them. A phone counts when the person opted
    # in to texts, or when written consent was acknowledged for this audience (the same
    # rule CampaignSender#sms_opt_in_ok? applies to each text).
    def apply_any_channel_reachability(relation)
      klass = relation.klass
      return relation unless klass.column_names.include?('email') && klass.column_names.include?('phone')

      table = klass.table_name
      emailable = apply_email_reachability(klass.unscoped.where(company_id: @company.id)).select(:id)
      textable = klass.unscoped.where(company_id: @company.id).where.not(phone: [nil, ''])
      unless @sms_consent_acknowledged
        col = %w[opt_in_sms sms_opt_in].find { |c| klass.column_names.include?(c) }
        textable = col ? textable.where(col => true) : textable.none
      end
      relation.where("#{table}.id IN (?) OR #{table}.id IN (?)", emailable, textable.select(:id))
    end

    def apply_email_reachability(relation)
      klass = relation.klass
      return relation unless klass.column_names.include?('email')

      relation = relation.where.not(email: [nil, ''])

      # Accounts have no email_invalid column; only Lead and Contact carry the CRM flag.
      if klass.column_names.include?('email_invalid')
        relation = relation.where(email_invalid: [false, nil])
      end

      # Compared lowercased because suppressions are stored downcased on write while CRM
      # addresses are stored as typed, so a mixed-case lead would otherwise slip past the
      # exact match and be mailed again.
      suppressed = CampaignSuppression.unmailable_emails_for(@company.id)
      relation.where.not("LOWER(#{klass.table_name}.email) IN (#{suppressed.to_sql})")
    end

    def base_relation
      case @source_type
      when 'Lead'
        @company.leads
      when 'Contact'
        @company.contacts.where(is_deleted: [false, nil])
      when 'Account'
        @company.accounts.where(is_deleted: [false, nil])
      else
        raise CompilationError, "Unsupported source_type: #{@source_type}"
      end
    end

    def apply_node(scope, node)
      return scope if node.blank?

      type = node['type'] || node['logic']
      children = Array(node['children'] || node['conditions'])

      if type == 'or'
        return apply_or(scope, children)
      elsif type == 'and' || type.blank?
        children.each do |child|
          next unless child.is_a?(Hash)
          if child['type'] || child['logic'] || child['children'] || child['conditions']
            scope = apply_node(scope, child)
          elsif child['operator']
            scope = apply_leaf(scope, child)
          end
        end
        return scope
      end

      scope
    end

    def apply_or(scope, children)
      sub_scopes = children.map do |child|
        next unless child.is_a?(Hash)
        if child['type'] || child['logic']
          apply_node(base_relation, child)
        elsif child['operator']
          apply_leaf(base_relation, child)
        end
      end.compact

      return scope if sub_scopes.empty?

      union_sql = sub_scopes.map { |s| s.select(:id).to_sql }.join(' UNION ')
      scope.where("#{scope.model.table_name}.id IN (#{union_sql})")
    end

    def apply_leaf(scope, leaf)
      field = leaf['field']
      operator = leaf['operator']
      value = leaf['value']

      raise CompilationError, "Unsupported operator: #{operator}" unless SUPPORTED_OPERATORS.include?(operator)

      return apply_tag_leaf(scope, operator, value) if operator.start_with?('tags_')
      return apply_custom_field_leaf(scope, field, operator, value) if field.to_s.start_with?(FieldSchema::CUSTOM_FIELD_PREFIX)

      if VIRTUAL_FIELDS.include?(field)
        return apply_virtual_leaf(scope, field, operator, value)
      end

      column = resolve_column(field)
      raise CompilationError, "Unknown field: #{field}" unless column

      table = scope.model.table_name
      qualified = "#{table}.#{column}"

      if CASE_INSENSITIVE_FIELDS.include?(column) && %w[equals not_equals in not_in].include?(operator)
        return apply_case_insensitive_leaf(scope, qualified, operator, value)
      end

      case operator
      when 'equals'
        scope.where(column => value)
      when 'not_equals'
        scope.where.not(column => value)
      when 'contains'
        scope.where("#{qualified} ILIKE ?", "%#{escape_like(value.to_s)}%")
      when 'not_contains'
        scope.where("#{qualified} NOT ILIKE ?", "%#{escape_like(value.to_s)}%")
      when 'starts_with'
        scope.where("#{qualified} ILIKE ?", "#{escape_like(value.to_s)}%")
      when 'ends_with'
        scope.where("#{qualified} ILIKE ?", "%#{escape_like(value.to_s)}")
      when 'greater_than'
        scope.where("#{qualified} > ?", value)
      when 'less_than'
        scope.where("#{qualified} < ?", value)
      when 'greater_than_or_equal'
        scope.where("#{qualified} >= ?", value)
      when 'less_than_or_equal'
        scope.where("#{qualified} <= ?", value)
      when 'is_set'
        scope.where.not(column => [nil, ''])
      when 'is_blank'
        scope.where(column => [nil, ''])
      when 'in'
        scope.where(column => Array(value))
      when 'not_in'
        scope.where.not(column => Array(value))
      when 'days_since_greater_than'
        days = value.to_i
        scope.where("#{qualified} < ?", days.days.ago)
      end
    end

    # Values live in the custom_field_values JSONB, written by forms and imports,
    # so a number can arrive as 8.0 or "8" and a bad one must not break the query.
    # Nothing here casts: numbers are guarded by pattern, dates compare as ISO text.
    def apply_custom_field_leaf(scope, field, operator, value)
      key = field.to_s.delete_prefix(FieldSchema::CUSTOM_FIELD_PREFIX)
      definition = custom_field_definitions[key]
      raise CompilationError, "Unknown field: #{field}" unless definition

      table = scope.model.table_name
      json = "#{table}.custom_field_values->#{scope.connection.quote(key)}"
      text = "#{table}.custom_field_values->>#{scope.connection.quote(key)}"

      return scope.where("TRIM(COALESCE(#{text}, '')) NOT IN ('', '[]')") if operator == 'is_set'
      return scope.where("TRIM(COALESCE(#{text}, '')) IN ('', '[]')") if operator == 'is_blank'

      case definition.field_type
      when 'multiselect' then apply_custom_multiselect_leaf(scope, json, operator, value)
      when 'number', 'currency', 'percent' then apply_custom_number_leaf(scope, text, operator, value)
      when 'date', 'datetime' then apply_custom_date_leaf(scope, text, operator, value)
      when 'checkbox' then apply_custom_checkbox_leaf(scope, text, value)
      else apply_custom_text_leaf(scope, text, operator, value)
      end
    end

    def apply_custom_text_leaf(scope, text, operator, value)
      normalized = "LOWER(TRIM(COALESCE(#{text}, '')))"
      values = Array(value).map { |v| v.to_s.strip.downcase }.reject(&:empty?)
      return scope if values.empty?

      case operator
      when 'equals', 'in' then scope.where("#{normalized} IN (:values)", values: values)
      # NOT matches a record with no value too, as not_equals on any other field does.
      when 'not_equals', 'not_in' then scope.where("#{normalized} NOT IN (:values)", values: values)
      when 'contains' then scope.where("#{text} ILIKE :pattern", pattern: "%#{escape_like(values.first)}%")
      when 'not_contains' then scope.where("COALESCE(#{text}, '') NOT ILIKE :pattern", pattern: "%#{escape_like(values.first)}%")
      when 'starts_with' then scope.where("TRIM(#{text}) ILIKE :pattern", pattern: "#{escape_like(values.first)}%")
      when 'ends_with' then scope.where("TRIM(#{text}) ILIKE :pattern", pattern: "%#{escape_like(values.first)}")
      else raise CompilationError, "Operator #{operator} not supported on this custom field"
      end
    end

    # Stored as a JSON array; jsonb_exists_any also matches a lone string from an import.
    def apply_custom_multiselect_leaf(scope, json, operator, value)
      values = Array(value).map(&:to_s).reject(&:empty?)
      return scope if values.empty?

      matches = "COALESCE(jsonb_exists_any(#{json}, ARRAY[:values]::text[]), FALSE)"
      case operator
      when 'in', 'equals' then scope.where(matches, values: values)
      when 'not_in', 'not_equals' then scope.where("NOT #{matches}", values: values)
      else raise CompilationError, "Operator #{operator} not supported on this custom field"
      end
    end

    NUMBER_COMPARISONS = {
      'equals' => '=', 'greater_than' => '>', 'less_than' => '<',
      'greater_than_or_equal' => '>=', 'less_than_or_equal' => '<='
    }.freeze

    def apply_custom_number_leaf(scope, text, operator, value)
      comparison = NUMBER_COMPARISONS[operator]
      raise CompilationError, "Operator #{operator} not supported on this custom field" unless comparison

      number = BigDecimal(value.to_s, exception: false)
      return scope unless number

      numeric = "CASE WHEN TRIM(#{text}) ~ '^-?[0-9]+([.][0-9]+)?$' THEN TRIM(#{text})::numeric END"
      scope.where("(#{numeric}) #{comparison} :number", number: number)
    end

    def apply_custom_date_leaf(scope, text, operator, value)
      day = "CASE WHEN #{text} ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ].*)?$' THEN LEFT(#{text}, 10) END"
      case operator
      when 'days_since_greater_than'
        scope.where("(#{day}) COLLATE \"C\" < :day", day: value.to_i.days.ago.to_date.iso8601)
      when 'greater_than', 'less_than'
        return scope if value.to_s.strip.empty?

        comparison = operator == 'greater_than' ? '>' : '<'
        scope.where("(#{day}) COLLATE \"C\" #{comparison} :day", day: value.to_s.strip.first(10))
      else
        raise CompilationError, "Operator #{operator} not supported on this custom field"
      end
    end

    # A record never saved with the box ticked has no value, which reads as No.
    def apply_custom_checkbox_leaf(scope, text, value)
      ticked = "LOWER(TRIM(COALESCE(#{text}, ''))) IN ('true', 't', '1', 'yes')"
      ActiveModel::Type::Boolean.new.cast(value) ? scope.where(ticked) : scope.where("NOT (#{ticked})")
    end

    # Includes turned-off fields, so an audience saved on one keeps working.
    def custom_field_definitions
      @custom_field_definitions ||= FieldSchema.custom_field_definitions(@source_type, @company).index_by(&:field_key)
    end

    # NOT matches a blank column too, as not_equals on any other field does.
    def apply_case_insensitive_leaf(scope, qualified, operator, value)
      values = Array(value).map { |v| v.to_s.strip.downcase }.reject(&:empty?)
      return scope if values.empty?

      normalized = "LOWER(TRIM(#{qualified}))"
      if operator.start_with?('not')
        scope.where("#{qualified} IS NULL OR #{normalized} NOT IN (?)", values)
      else
        scope.where("#{normalized} IN (?)", values)
      end
    end

    # Virtual fields resolve through a join (source_name, owner_name).
    # We compute matching IDs in a subquery so we don't pollute the outer scope's joins.
    def apply_virtual_leaf(scope, field, operator, value)
      table = scope.model.table_name

      case field
      when 'source_name'
        return scope.where("#{table}.source_id IS NOT NULL") if operator == 'is_set'
        return scope.where("#{table}.source_id IS NULL") if operator == 'is_blank'

        matching_source_ids = Source.where(company_id: @company.id)
        case operator
        when 'equals'
          matching_source_ids = matching_source_ids.where('sources.name = ?', value)
        when 'not_equals'
          matching_source_ids = matching_source_ids.where('sources.name <> ?', value)
        when 'contains'
          matching_source_ids = matching_source_ids.where('sources.name ILIKE ?', "%#{escape_like(value.to_s)}%")
        when 'in'
          matching_source_ids = matching_source_ids.where('sources.name IN (?)', Array(value))
        when 'not_in'
          matching_source_ids = matching_source_ids.where.not('sources.name IN (?)', Array(value))
        else
          raise CompilationError, "Operator #{operator} not supported on source_name"
        end

        ids_sub = matching_source_ids.select(:id)
        if operator == 'not_equals' || operator == 'not_in'
          scope.where("#{table}.source_id IS NULL OR #{table}.source_id IN (?)", ids_sub)
        else
          scope.where("#{table}.source_id IN (?)", ids_sub)
        end

      when 'owner_name'
        return scope.where("#{table}.owner_id IS NOT NULL") if operator == 'is_set'
        return scope.where("#{table}.owner_id IS NULL") if operator == 'is_blank'

        name_expr = "(COALESCE(users.first_name, '') || ' ' || COALESCE(users.last_name, ''))"
        matching_user_ids = User.all
        case operator
        when 'equals'
          v = value.to_s
          matching_user_ids = matching_user_ids.where(
            "TRIM(#{name_expr}) = ? OR users.email = ? OR users.name = ?",
            v, v, v
          )
        when 'not_equals'
          v = value.to_s
          matching_user_ids = matching_user_ids.where.not(
            "TRIM(#{name_expr}) = ? OR users.email = ? OR users.name = ?",
            v, v, v
          )
        when 'contains'
          pattern = "%#{escape_like(value.to_s)}%"
          matching_user_ids = matching_user_ids.where(
            "#{name_expr} ILIKE ? OR users.email ILIKE ? OR users.name ILIKE ?",
            pattern, pattern, pattern
          )
        else
          raise CompilationError, "Operator #{operator} not supported on owner_name"
        end

        ids_sub = matching_user_ids.select(:id)
        if operator == 'not_equals'
          scope.where("#{table}.owner_id IS NULL OR #{table}.owner_id IN (?)", ids_sub)
        else
          scope.where("#{table}.owner_id IN (?)", ids_sub)
        end
      end
    end

    def apply_tag_leaf(scope, operator, value)
      # Accept both shapes: TagsValueInput stores an array even for the
      # scalar operators (tags_include/tags_exclude), and normalize_tag_leaves!
      # emits a scalar. Flatten in both cases so neither shape produces
      # zero matches through Array double-wrap.
      tag_values = Array(value).flatten

      string_vals = tag_values.select { |v| v.is_a?(String) && v !~ /\A\d+\z/ }
      int_vals = tag_values.select { |v| v.is_a?(Integer) || (v.is_a?(String) && v =~ /\A\d+\z/) }.map(&:to_i)

      tag_clauses = []
      tag_params = []
      if string_vals.any?
        tag_clauses << 'tags.name IN (?)'
        tag_params << string_vals
      end
      if int_vals.any?
        tag_clauses << 'tags.id IN (?)'
        tag_params << int_vals
      end
      return scope if tag_clauses.empty?

      table = scope.model.table_name
      entity_type = scope.model.name
      tag_join_sql = <<~SQL.squish
        INNER JOIN tag_assignments
          ON tag_assignments.entity_type = '#{entity_type}'
         AND tag_assignments.entity_id = #{table}.id
        INNER JOIN tags
          ON tags.id = tag_assignments.tag_id
      SQL
      ids_subquery = scope.model
                          .joins(tag_join_sql)
                          .where([tag_clauses.join(' OR '), *tag_params])
                          .select(:id)

      case operator
      when 'tags_include', 'tags_any_of'
        scope.where("#{table}.id IN (?)", ids_subquery)
      when 'tags_exclude'
        scope.where("#{table}.id NOT IN (?)", ids_subquery)
      end
    end

    def resolve_column(field)
      allowed = allowed_columns_for_source
      allowed.include?(field) ? field : nil
    end

    def allowed_columns_for_source
      case @source_type
      when 'Lead'
        # is_converted: a recurring audience ("every lead who wants the weekly
        # homes email") must be able to let a lead go once it becomes a deal.
        %w[first_name last_name email phone status source_id health_score opt_in_sms last_activity_at created_at updated_at company_name title location_id owner_id is_converted] + ADDRESS_COLUMNS['Lead']
      when 'Contact'
        %w[first_name last_name email phone opt_in_sms account_id created_at updated_at company_name title location_id owner_id] + ADDRESS_COLUMNS['Contact']
      when 'Account'
        %w[name account_type website created_at updated_at] + ADDRESS_COLUMNS['Account']
      else
        []
      end
    end

    def escape_like(str)
      str.gsub(/[\\%_]/) { |c| "\\#{c}" }
    end

    def sample_row(record)
      base = { id: record.id }
      case @source_type
      when 'Lead', 'Contact'
        base.merge(
          name: [record.try(:first_name), record.try(:last_name)].compact.join(' ').presence || record.try(:email),
          email: record.try(:email)
        )
      when 'Account'
        base.merge(name: record.name, account_type: record.try(:account_type))
      end
    end
  end
end
