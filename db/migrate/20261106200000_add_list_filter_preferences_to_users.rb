# frozen_string_literal: true

# The filters each person last used on the lead, contact, account and deal
# lists, so a new login opens where they left off instead of on "mine".
# Shape: { "<company_id>": { "leads": { "owner": "all", ... }, ... } }, keyed by
# company because a platform admin moves between tenants.
class AddListFilterPreferencesToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :list_filter_preferences, :jsonb, default: {}, null: false
  end
end
