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

    def initialize(company:, source_type:, filter_tree:, exclude_filter_tree: nil)
      @company = company
      @source_type = source_type
      @filter_tree = filter_tree.is_a?(Hash) ? filter_tree.deep_stringify_keys : {}
      @exclude_filter_tree = exclude_filter_tree.is_a?(Hash) ? exclude_filter_tree.deep_stringify_keys : nil
    end

    def scope
      base = base_relation
      base = apply_node(base, @filter_tree) if @filter_tree.present?

      if @exclude_filter_tree.present?
        excluded_ids_scope = apply_node(base_relation, @exclude_filter_tree).select(:id)
        base = base.where.not(id: excluded_ids_scope)
      end

      base
    end

    def count
      scope.count
    end

    def sample(limit: 5)
      scope.limit(limit).map { |r| sample_row(r) }
    end

    private

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

    def apply_tag_leaf(scope, operator, value)
      tag_values = operator == 'tags_any_of' ? Array(value) : [value]

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
        %w[first_name last_name email phone status source_id health_score opt_in_sms last_activity_at created_at updated_at]
      when 'Contact'
        %w[first_name last_name email phone opt_in_sms account_id created_at updated_at]
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
