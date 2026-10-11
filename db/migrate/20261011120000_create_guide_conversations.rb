# frozen_string_literal: true

# Help assistant conversations (backlog E75, phase 4): one per person per
# thread, so follow-up questions have the earlier ones as context.
class CreateGuideConversations < ActiveRecord::Migration[8.0]
  def change
    create_table :guide_conversations do |t|
      t.bigint :company_id, null: false
      t.bigint :user_id,    null: false
      t.jsonb  :messages,   null: false, default: []
      t.timestamps
    end
    add_index :guide_conversations, %i[user_id updated_at]
  end
end
