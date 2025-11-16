# frozen_string_literal: true

class CreateLocationActivities < ActiveRecord::Migration[8.0]
  def change
    create_table :location_activities do |t|
      t.references :location, null: false, foreign_key: true
      t.references :user, null: true, foreign_key: true
      t.string :action, null: false
      t.string :category, null: false
      t.text :description
      t.jsonb :metadata, default: {}
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :location_activities, :category
    add_index :location_activities, :action
    add_index :location_activities, :occurred_at
    add_index :location_activities, [:location_id, :occurred_at]
  end
end
