# frozen_string_literal: true

# Questions the help assistant hands to support instead of answering (E118):
# something that looks wrong, a feature we do not offer, or a change the
# person wants made. Each keeps the whole exchange so support can act on it.
# A new table only, so the code running during the release is unaffected.
class CreateGuideFlags < ActiveRecord::Migration[8.0]
  def change
    create_table :guide_flags do |t|
      t.bigint :company_id
      t.bigint :user_id
      t.bigint :guide_conversation_id
      t.string :kind, null: false
      t.string :status, null: false, default: 'new'
      t.text :question, null: false
      t.string :page
      t.string :source, null: false, default: 'help'
      t.text :assistant_reason
      t.text :answer_shown
      t.jsonb :tool_trace, null: false, default: []
      t.text :notes
      t.bigint :resolved_by_id
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :guide_flags, %i[kind status created_at]
    add_index :guide_flags, %i[company_id created_at]
  end
end
