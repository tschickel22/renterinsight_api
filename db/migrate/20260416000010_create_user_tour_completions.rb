# frozen_string_literal: true

class CreateUserTourCompletions < ActiveRecord::Migration[8.0]
  def change
    create_table :user_tour_completions do |t|
      t.references :user, null: false, foreign_key: true, index: true
      t.references :tour, null: false, foreign_key: true, index: true
      t.datetime :completed_at
      t.jsonb    :steps_completed, null: false, default: {}
      t.timestamps
    end

    add_index :user_tour_completions, [:user_id, :tour_id], unique: true
    add_index :user_tour_completions, :completed_at
  end
end
