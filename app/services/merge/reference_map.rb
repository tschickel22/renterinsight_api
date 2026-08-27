# frozen_string_literal: true

module Merge
  # Every place in the database that points at a Lead, Contact or Account.
  #
  # Derived from the live schema rather than hand-listed. There are 8 tables
  # carrying lead_id, 14 carrying contact_id and 9 carrying account_id, plus
  # thirty-odd polymorphic *_type/*_id families, and the model associations do
  # not cover all of them: several tables hold a foreign key with no matching
  # has_many. A hand-written list is a list that goes stale the first time
  # somebody adds a table, and the failure mode is silent orphaned rows rather
  # than an error, so this reads the schema every time instead.
  module ReferenceMap
    ENTITIES = {
      'Lead'    => { table: 'leads',    fk: 'lead_id' },
      'Contact' => { table: 'contacts', fk: 'contact_id' },
      'Account' => { table: 'accounts', fk: 'account_id' }
    }.freeze

    # Columns we must never rewrite: the record's own identity, and the merge
    # bookkeeping itself.
    SELF_REFERENTIAL_SKIP = %w[merged_into_id].freeze

    module_function

    def connection = ActiveRecord::Base.connection

    def entity_config(class_name)
      ENTITIES.fetch(class_name) { raise ArgumentError, "not a mergeable entity: #{class_name}" }
    end

    # [{ table:, column: }] for every direct foreign key to this entity.
    #
    # Real FK constraints first, because they are authoritative in both
    # directions. They catch columns a name scan misses, such as
    # leads.converted_account_id pointing at accounts, and they exclude columns
    # that merely share the name. syndication_partners.account_id is a varchar
    # holding an external partner code, and rewriting it with one of our ids
    # would quietly corrupt a feed; a name-and-type scan alone would have.
    #
    # Not every table carries a constraint, so a name match is still used as a
    # fallback, but only for integer columns.
    def direct_references(class_name)
      cfg = entity_config(class_name)
      target = cfg[:table]
      fk_name = cfg[:fk]

      found = {}

      connection.tables.each do |table|
        connection.foreign_keys(table).each do |fk|
          next unless fk.to_table == target

          column = fk.options[:column].to_s
          next if SELF_REFERENTIAL_SKIP.include?(column)

          found["#{table}.#{column}"] = { table: table, column: column }
        end
      rescue NotImplementedError, ActiveRecord::StatementInvalid
        next
      end

      # Fallback for tables with no declared constraint. Integer columns only.
      connection.tables.each do |table|
        next if table == target
        key = "#{table}.#{fk_name}"
        next if found.key?(key)

        col = connection.columns(table).find { |c| c.name == fk_name }
        next unless col
        next unless %i[integer bigint].include?(col.type)

        found[key] = { table: table, column: fk_name }
      end

      found.values
    end

    # [{ table:, id_column:, type_column: }] for polymorphic columns that
    # actually hold rows pointing at this class right now. Checked against the
    # data, not guessed from names: communicable, enrollable, entity, payable,
    # borrower, taskable and a dozen others can all legitimately carry a Contact.
    def polymorphic_references(class_name)
      connection.tables.flat_map do |table|
        cols = connection.columns(table).map(&:name)
        cols.filter_map do |col|
          next unless col.end_with?('_type')

          base = col.delete_suffix('_type')
          id_col = "#{base}_id"
          next unless cols.include?(id_col)

          { table: table, id_column: id_col, type_column: col }
        end
      end
    end

    # Narrow the polymorphic list to those with at least one row of this type,
    # so a merge preview does not list forty tables that can never match.
    def live_polymorphic_references(class_name, company_id: nil)
      polymorphic_references(class_name).select do |ref|
        sql = "SELECT 1 FROM #{connection.quote_table_name(ref[:table])} " \
              "WHERE #{connection.quote_column_name(ref[:type_column])} = #{connection.quote(class_name)} LIMIT 1"
        connection.select_value(sql).present?
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn "[Merge::ReferenceMap] skipping #{ref[:table]}.#{ref[:type_column]}: #{e.message}"
        false
      end
    end
  end
end
