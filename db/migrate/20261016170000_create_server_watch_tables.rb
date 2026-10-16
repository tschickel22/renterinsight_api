# frozen_string_literal: true

# Server watch (backlog E79): what tells Tom the servers are in trouble before
# a customer does. Boots (to tell a crash from a release), server errors (kept
# to look at, and counted for a spike), and marks (when an alert last went
# out, when background jobs last checked in).
class CreateServerWatchTables < ActiveRecord::Migration[8.0]
  def change
    create_table :server_boots do |t|
      t.string :service, null: false
      t.string :commit
      t.string :instance
      t.datetime :booted_at, null: false
    end
    add_index :server_boots, [:service, :booted_at]

    create_table :server_errors do |t|
      t.datetime :occurred_at, null: false
      t.string :request_method
      t.string :path
      t.integer :status
      t.string :error_class
      t.text :message
      t.string :request_id
    end
    add_index :server_errors, :occurred_at

    create_table :ops_marks do |t|
      t.string :key, null: false
      t.datetime :at, null: false
      t.string :note
    end
    add_index :ops_marks, :key, unique: true
  end
end
