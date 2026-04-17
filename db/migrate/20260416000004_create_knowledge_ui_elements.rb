# frozen_string_literal: true

class CreateKnowledgeUiElements < ActiveRecord::Migration[8.0]
  # element_type values: button, link, input, menu, section, card, tab, modal
  def change
    create_table :knowledge_ui_elements do |t|
      t.references :knowledge_feature, null: false, foreign_key: true, index: true
      t.string :selector,     null: false
      t.string :label
      t.string :element_type, null: false, default: 'button'
      t.text   :tour_hint
      t.timestamps
    end

    add_index :knowledge_ui_elements, :element_type
    add_index :knowledge_ui_elements, [:knowledge_feature_id, :selector], unique: true,
              name: 'idx_knowledge_ui_elements_on_feature_and_selector'
  end
end
