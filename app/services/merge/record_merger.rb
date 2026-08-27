# frozen_string_literal: true

module Merge
  # Merges a duplicate CRM record into a surviving one.
  #
  # Standard survivorship, the same shape Salesforce and HubSpot use: the user
  # picks which record survives, optionally picks a winning value per field,
  # every related row is re-parented onto the survivor, and the loser is
  # retired rather than destroyed so the merge stays auditable and undoable.
  #
  # Nothing here is destructive. The loser keeps all its own column values and
  # simply gains merged_into_id, which is what every list scope filters on. If a
  # merge turns out to be wrong, the record is still there to restore.
  class RecordMerger
    class MergeError < StandardError; end

    # Columns that describe the row itself rather than the person or business,
    # so they must never be copied from the loser onto the survivor.
    BOOKKEEPING = %w[
      id company_id created_at updated_at merged_into_id merged_at merged_by_id
    ].freeze

    Result = Struct.new(:survivor, :merged, :moved, :fields_taken, :warnings, keyword_init: true)

    def self.call(...) = new(...).call

    # preview: true computes everything and rolls back, so the UI can show the
    # user exactly what a merge would do before they commit to it.
    def initialize(survivor:, loser:, actor: nil, field_overrides: {}, preview: false)
      @survivor        = survivor
      @loser           = loser
      @actor           = actor
      @field_overrides = (field_overrides || {}).stringify_keys
      @preview         = preview
      @warnings        = []
    end

    def call
      validate!

      moved  = Hash.new(0)
      taken  = {}

      ActiveRecord::Base.transaction do
        taken = apply_field_survivorship!
        moved = reparent_references!
        retire_loser!

        raise ActiveRecord::Rollback if @preview
      end

      Result.new(survivor: @survivor, merged: @loser, moved: moved,
                 fields_taken: taken, warnings: @warnings)
    end

    private

    def klass = @survivor.class

    def validate!
      raise MergeError, 'Records must be the same type' unless @loser.is_a?(klass)
      raise MergeError, 'Cannot merge a record into itself' if @survivor.id == @loser.id

      # Tenant isolation is the whole ballgame here: a merge rewrites foreign
      # keys across thirty-odd tables, so a cross-company merge would hand one
      # dealer's records to another and there is no clean way back.
      if @survivor.company_id.blank? || @survivor.company_id != @loser.company_id
        raise MergeError, 'Records belong to different companies'
      end

      raise MergeError, 'Survivor has already been merged away' if @survivor.merged_into_id.present?
      raise MergeError, 'Duplicate has already been merged away' if @loser.merged_into_id.present?
    end

    # Survivor wins by default. A blank field on the survivor is filled from the
    # loser, because the usual reason a duplicate exists is that each copy holds
    # something the other lacks. Explicit overrides from the UI beat both.
    def apply_field_survivorship!
      taken = {}

      mergeable_columns.each do |col|
        if @field_overrides.key?(col)
          chosen = @field_overrides[col]
          next if chosen.to_s == @survivor[col].to_s

          @survivor[col] = chosen
          taken[col] = { from: 'override', value: chosen }
        elsif blank_value?(@survivor[col]) && !blank_value?(@loser[col])
          @survivor[col] = @loser[col]
          taken[col] = { from: 'duplicate', value: @loser[col] }
        end
      end

      @survivor.save! if taken.any?
      taken
    end

    def mergeable_columns
      klass.column_names - BOOKKEEPING
    end

    def blank_value?(v)
      v.nil? || (v.respond_to?(:strip) && v.strip.empty?)
    end

    # Rewrites every direct and polymorphic pointer from the loser to the
    # survivor. Uses update_all deliberately: these are pure key rewrites across
    # tables whose callbacks would otherwise fire in the thousands, and several
    # of the child models validate against state the merge is mid-way through
    # changing.
    def reparent_references!
      moved = Hash.new(0)
      name  = klass.name

      ReferenceMap.direct_references(name).each do |ref|
        moved["#{ref[:table]}.#{ref[:column]}"] += move_rows(ref[:table], ref[:column])
      end

      ReferenceMap.live_polymorphic_references(name).each do |ref|
        moved["#{ref[:table]}.#{ref[:id_column]}"] +=
          move_rows(ref[:table], ref[:id_column], type_column: ref[:type_column], type_value: name)
      end

      moved.reject { |_k, v| v.zero? }
    end

    def move_rows(table, column, type_column: nil, type_value: nil)
      conn  = ActiveRecord::Base.connection
      where = +"#{conn.quote_column_name(column)} = #{conn.quote(@loser.id)}"
      where << " AND #{conn.quote_column_name(type_column)} = #{conn.quote(type_value)}" if type_column

      sql = "UPDATE #{conn.quote_table_name(table)} " \
            "SET #{conn.quote_column_name(column)} = #{conn.quote(@survivor.id)} WHERE #{where}"
      conn.update(sql)
    rescue ActiveRecord::RecordNotUnique => e
      # A unique index on (owner_id, something) can legitimately collide: the
      # same tag on both records, the same enrolment in one campaign. Losing the
      # duplicate row is correct, but say so rather than swallowing it.
      @warnings << "#{table}.#{column}: some rows could not move because the survivor already has them (#{e.message.truncate(120)})"
      0
    rescue ActiveRecord::StatementInvalid => e
      raise MergeError, "Failed moving #{table}.#{column}: #{e.message.truncate(200)}"
    end

    def retire_loser!
      @loser.merged_into_id = @survivor.id
      @loser.merged_at      = Time.current
      @loser.merged_by_id   = @actor&.id
      @loser.save!(validate: false)
    end
  end
end
