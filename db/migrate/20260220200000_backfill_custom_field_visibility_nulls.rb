# frozen_string_literal: true

class BackfillCustomFieldVisibilityNulls < ActiveRecord::Migration[8.0]
  def up
    # Backfill any custom fields with NULL visibility to 'both'
    # Using 'both' because that was the original default when the column was first added,
    # meaning these fields were likely created before the default was changed to 'internal'.
    # This ensures existing fields continue to display publicly as they did before.
    execute <<-SQL
      UPDATE custom_fields
      SET visibility = 'both'
      WHERE visibility IS NULL
    SQL

    # Also enforce NOT NULL going forward
    change_column_null :custom_fields, :visibility, false, 'internal'
  end

  def down
    change_column_null :custom_fields, :visibility, true
  end
end
