class ConvertTagAssignmentsEntityIdToBigint < ActiveRecord::Migration[8.0]
  # tag_assignments.entity_id is varchar; FKs to leads.id, contacts.id, accounts.id
  # which are bigint. This causes type mismatch errors when joining without an
  # explicit cast. Convert to bigint with backfill.

  def up
    bad_count = execute(<<~SQL).first['bad'].to_i
      SELECT COUNT(*) AS bad FROM tag_assignments WHERE entity_id !~ '^[0-9]+$'
    SQL

    if bad_count > 0
      raise ActiveRecord::IrreversibleMigration,
            "Found #{bad_count} non-numeric entity_id values in tag_assignments. " \
            "Inspect with: SELECT id, entity_type, entity_id FROM tag_assignments WHERE entity_id !~ '^[0-9]+$'; " \
            "Clean these up before running this migration."
    end

    execute <<~SQL
      ALTER TABLE tag_assignments
      ALTER COLUMN entity_id TYPE bigint
      USING entity_id::bigint
    SQL

    indexes = ActiveRecord::Base.connection.indexes(:tag_assignments)
    has_combo = indexes.any? { |i| i.columns == %w[entity_type entity_id] }

    unless has_combo
      add_index :tag_assignments, [:entity_type, :entity_id], name: 'idx_tag_assignments_entity_type_id'
    end
  end

  def down
    execute <<~SQL
      ALTER TABLE tag_assignments
      ALTER COLUMN entity_id TYPE varchar
      USING entity_id::varchar
    SQL
  end
end
