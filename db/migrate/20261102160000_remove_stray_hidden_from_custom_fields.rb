# frozen_string_literal: true

# custom_fields.hidden was in schema.rb from February with no migration behind it,
# and existed only on local databases. Staging and production never had it, so
# this does nothing there; it clears local copies so a schema dump can't restore it.
class RemoveStrayHiddenFromCustomFields < ActiveRecord::Migration[8.0]
  def up
    remove_column :custom_fields, :hidden, if_exists: true
  end

  def down; end
end
