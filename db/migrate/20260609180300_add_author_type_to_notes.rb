# frozen_string_literal: true

# Distinguishes who authored a note: "staff" (internal user) vs "customer"
# (a portal reply). Used to badge messages in the shared customer-facing thread.
# Existing/backfilled notes default to "staff".
class AddAuthorTypeToNotes < ActiveRecord::Migration[8.0]
  def change
    add_column :notes, :author_type, :string, null: false, default: 'staff' unless column_exists?(:notes, :author_type)
  end
end
