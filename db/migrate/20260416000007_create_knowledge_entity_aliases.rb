# frozen_string_literal: true

# Maps synonyms to a canonical entity key (module / feature / model / permission).
#
# NOTE: Column is named `alias_name` instead of `alias` because `alias` is a Ruby
# reserved keyword — `record.alias` is a SyntaxError. Access via `record.alias_name`.
# entity_type values: module, feature, model, permission, action, route
class CreateKnowledgeEntityAliases < ActiveRecord::Migration[8.0]
  def change
    create_table :knowledge_entity_aliases do |t|
      t.string :canonical_key, null: false
      t.string :alias_name,    null: false
      t.string :entity_type,   null: false, default: 'module'
      t.timestamps
    end

    add_index :knowledge_entity_aliases, :canonical_key
    add_index :knowledge_entity_aliases, :alias_name
    add_index :knowledge_entity_aliases, [:entity_type, :alias_name], unique: true,
              name: 'idx_knowledge_aliases_on_type_and_alias'
  end
end
