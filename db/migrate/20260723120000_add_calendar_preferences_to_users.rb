# frozen_string_literal: true

class AddCalendarPreferencesToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :calendar_preferences, :jsonb, default: {}, null: false
  end
end
