# frozen_string_literal: true

class AddWorkqueuePreferencesToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :workqueue_preferences, :jsonb, default: {}, null: false
  end
end
