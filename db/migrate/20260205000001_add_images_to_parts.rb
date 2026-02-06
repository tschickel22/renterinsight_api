# frozen_string_literal: true

class AddImagesToParts < ActiveRecord::Migration[8.0]
  def change
    # Skip if column already exists
    return if column_exists?(:parts, :images)
    
    add_column :parts, :images, :jsonb, default: []
    add_index :parts, :images, using: :gin
  end
end
