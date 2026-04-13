# frozen_string_literal: true

class AddLastActivityAtToLeadsAndDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :leads, :last_activity_at, :datetime
    add_column :deals, :last_activity_at, :datetime
    add_index :leads, [:owner_id, :last_activity_at]
    add_index :deals, [:user_id, :last_activity_at]
  end
end
