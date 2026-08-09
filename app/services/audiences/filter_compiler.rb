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

    def initialize(company:, source_type:, filter_tree:,
                   exclude_filter_tree: nil,
                   manual_include_ids: nil,
                   manual_exclude_ids: nil,
                   exclude_active_campaign_enrollees: false,
                   exclude_active_nurture_enrollees: false,
                   channel: 'email')
      @company = company
      @source_type = source_type
      @channel = channel.to_s.presence || 'email'
      @filter_tree = filter_tree.is_a?(Hash) ? filter_tree.deep_stringify_keys : {}
      @exclude_filter_tree = exclude_filter_tree.is_a?(Hash) ? exclude_filter_tree.deep_stringify_keys : nil
      @manual_include_ids = Array(manual_include_ids).map(&:to_i).reject(&:zero?)
      @manual_exclude_ids = Array(manual_exclude_ids).map(&:to_i).reject(&:zero?)
      @exclude_active_campaign_enrollees = ActiveModel::Type::Boolean.new.cast(exclude_active_campaign_enrollees)
      @exclude_active_nurture_enrollees = ActiveModel::Type::Boolean.new.cast(exclude_active_nurture_enrollees)
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
          .select(:recipient_id)
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

      if VIRTUAL_FIELDS.include?(field)
        return apply_virtual_leaf(scope, field, operator, value)
      end

      column = resolve_column(field)
      raise CompilationError, "Unknown field: #{field}" unless column

      table = scope.model.table_name
      qualified = "#{table}.#{column}"

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
        %w[first_name last_name email phone status source_id health_score opt_in_sms last_activity_at created_at updated_at company_name title location_id owner_id]
      when 'Contact'
        %w[first_name last_name email phone opt_in_sms account_id created_at updated_at company_name title location_id owner_id]
      when 'Account'
        %w[name account_type website created_at updated_at]
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
