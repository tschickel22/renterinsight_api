# frozen_string_literal: true

# `changes` collides with ActiveModel::Dirty#changes on every AR instance,
# which silently breaks both attribute assignment in .create() and any
# instance method that tries to read the column. Rename to `field_changes`.
class RenameChangesOnChampionImsSyncEvents < ActiveRecord::Migration[8.0]
  def change
    rename_column :champion_ims_sync_events, :changes, :field_changes
  end
end
