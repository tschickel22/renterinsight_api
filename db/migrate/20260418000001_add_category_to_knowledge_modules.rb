# frozen_string_literal: true

# Group modules into display categories ("CRM & Sales", "Finance", etc.) so
# the frontend can render a categorized module picker without hardcoding the
# grouping in its own source.
class AddCategoryToKnowledgeModules < ActiveRecord::Migration[8.0]
  def change
    add_column :knowledge_modules, :category, :string
    add_index  :knowledge_modules, :category
  end
end
