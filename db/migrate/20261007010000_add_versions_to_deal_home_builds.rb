# frozen_string_literal: true

# Versions of a deal's sheet (backlog E49): a rep prices a second home or a
# different option set beside the first, and one version is LIVE. Only the
# LIVE version writes the deal's products, discounts, tax and totals; the
# others are drafts for comparing and showing the buyer.
class AddVersionsToDealHomeBuilds < ActiveRecord::Migration[8.0]
  def up
    add_column :deal_home_builds, :version_number, :integer, null: false, default: 1
    add_column :deal_home_builds, :label, :string
    add_column :deal_home_builds, :live, :boolean, null: false, default: false
    # Every build so far was its deal's only one, so it is the live version.
    execute 'UPDATE deal_home_builds SET live = TRUE, version_number = 1'

    remove_index :deal_home_builds, :deal_id
    add_index :deal_home_builds, %i[deal_id version_number], unique: true
    add_index :deal_home_builds, :deal_id, unique: true, where: 'live', name: 'index_deal_home_builds_one_live_per_deal'
  end

  def down
    execute 'DELETE FROM deal_home_builds WHERE NOT live'
    remove_index :deal_home_builds, name: 'index_deal_home_builds_one_live_per_deal'
    remove_index :deal_home_builds, %i[deal_id version_number]
    add_index :deal_home_builds, :deal_id, unique: true
    remove_column :deal_home_builds, :live
    remove_column :deal_home_builds, :label
    remove_column :deal_home_builds, :version_number
  end
end
