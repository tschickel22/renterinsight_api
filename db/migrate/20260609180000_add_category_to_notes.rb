# frozen_string_literal: true

# Adds a category discriminator to notes so a single entity can host multiple
# independent note streams. Service tickets use this to keep "customer" and
# "technician" notes separate while reusing the generic Note infrastructure.
# Existing notes default to "general", preserving current behavior.
class AddCategoryToNotes < ActiveRecord::Migration[8.0]
  def change
    add_column :notes, :category, :string, null: false, default: 'general' unless column_exists?(:notes, :category)
    add_index :notes, [:entity_type, :entity_id, :category], name: 'index_notes_on_entity_and_category' unless index_exists?(:notes, [:entity_type, :entity_id, :category], name: 'index_notes_on_entity_and_category')
  end
end
