# frozen_string_literal: true

# Website chat runs on Quinn and shows in the Inbox (E96, 2026-11-07). A chat is
# a Conversation with channel web_chat, keyed by a random token the visitor's
# browser keeps; its messages live in chat_messages rather than communications,
# because a chat starts before there is a lead to hang a communication on.
# Additive only (new table, new nullable columns), safe beside running code.
class AddWebChatToConversations < ActiveRecord::Migration[8.0]
  def change
    add_column :conversations, :visitor_token, :string
    add_column :conversations, :website_id, :bigint
    add_column :conversations, :visitor_seen_at, :datetime
    # The page the chat was on: a dealer's own site (embed) or one we host.
    add_column :conversations, :chat_page_url, :string
    add_index :conversations, :visitor_token, unique: true, where: 'visitor_token IS NOT NULL'

    create_table :chat_messages do |t|
      t.references :conversation, null: false, foreign_key: true
      t.bigint :company_id, null: false
      t.string :direction, null: false # inbound (visitor) or outbound
      t.string :sent_by # visitor, assistant, user, system
      t.bigint :user_id
      t.text :body, null: false
      # Homes and buttons the chat showed with this message.
      t.jsonb :listings, default: [], null: false
      t.jsonb :actions, default: [], null: false
      t.timestamps
    end
    add_index :chat_messages, %i[conversation_id id]
    add_index :chat_messages, :company_id
  end
end
