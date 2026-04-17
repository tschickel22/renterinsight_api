# frozen_string_literal: true

class CreateTourSteps < ActiveRecord::Migration[8.0]
  # placement values:       top, bottom, left, right, center, auto
  # highlight_type values:  outline, overlay, pulse, none
  def change
    create_table :tour_steps do |t|
      t.references :tour,     null: false, foreign_key: true, index: true
      t.integer :position,       null: false
      t.string  :selector
      t.string  :title
      t.text    :content
      t.string  :placement,      null: false, default: 'bottom'
      t.string  :highlight_type, null: false, default: 'outline'
      t.boolean :click_required, null: false, default: false
      t.boolean :input_required, null: false, default: false
      t.timestamps
    end

    add_index :tour_steps, [:tour_id, :position], unique: true
  end
end
