# frozen_string_literal: true

module Accounting
  module QboMigration
    # Stands in for Quickbooks::Client in fixture mode and in specs. Serves
    # recorded API responses from spec/fixtures/quickbooks/migration/:
    #   <Entity>.json          a QueryResponse holding every row of that entity
    #   report_<Name>.json     a report (TrialBalance, TransactionList)
    #   company_info.json      CompanyInfo
    #
    # query(sql) understands the WHERE clauses the adapter writes (=, <, <=,
    # >, >=, IN joined by AND) and STARTPOSITION/MAXRESULTS, so paging and
    # as-of filtering run exactly as they would against QuickBooks.
    class FixtureClient
      attr_reader :queries, :reports

      def initialize(dir: QboMigration::FIXTURE_DIR, overrides: {})
        @dir = Pathname.new(dir)
        @overrides = overrides.transform_keys(&:to_s)
        @queries = []
        @reports = []
      end

      def company_info
        load('company_info')
      end

      def report(name, params = {})
        @reports << [name, params]
        load("report_#{name}")
      end

      def query(sql)
        @queries << sql
        match = sql.match(/\ASELECT \* FROM (\w+)(?: WHERE (.+?))?(?: STARTPOSITION (\d+))?(?: MAXRESULTS (\d+))?\z/i)
        raise ArgumentError, "Fixture client cannot read: #{sql}" unless match

        entity = match[1]
        rows = Array(load(entity).dig('QueryResponse', entity))
        rows = rows.select { |row| matches?(row, match[2]) } if match[2]
        start = (match[3] || 1).to_i
        max = (match[4] || 1000).to_i
        page = rows[(start - 1), max] || []
        { 'QueryResponse' => { entity => page, 'startPosition' => start, 'maxResults' => page.size } }
      end

      private

      def load(name)
        return @overrides[name] if @overrides.key?(name)

        path = @dir.join("#{name}.json")
        path.exist? ? JSON.parse(path.read) : {}
      end

      def matches?(row, where)
        where.split(/\s+AND\s+/i).all? do |cond|
          m = cond.strip.match(/\A(\w+)\s*(<=|>=|=|<|>|IN)\s*(.+)\z/i)
          next true unless m

          field, op, raw = m[1], m[2].upcase, m[3].strip
          value = row[field]
          if op == 'IN'
            allowed = raw.delete('()').split(',').map { |v| v.strip.delete("'") }
            next allowed.sort == %w[false true] || allowed.include?(value.to_s)
          end

          compare(value, op, raw.delete("'"))
        end
      end

      def compare(value, op, expected)
        if expected.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          left = value.present? ? Date.parse(value.to_s) : nil
          right = Date.parse(expected)
        elsif %w[true false].include?(expected)
          return (value != false) == (expected == 'true') if op == '='
        else
          left = value.to_s.to_d
          right = expected.to_d
        end
        return false if left.nil?

        case op
        when '=' then left == right
        when '<' then left < right
        when '<=' then left <= right
        when '>' then left > right
        when '>=' then left >= right
        end
      end
    end
  end
end
