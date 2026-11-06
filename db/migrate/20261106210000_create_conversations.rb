# frozen_string_literal: true

# Lead Assistant and Inbox (backlog E96). One row per ongoing conversation with a
# buyer, shared by the AI assistant, the inbox and later website chat, so none of
# them keeps its own copy. Messages stay in `communications`; this row only says
# who the conversation is with, which number it runs on, and who is handling it.
class CreateConversations < ActiveRecord::Migration[8.0]
  def change
    create_table :conversations do |t|
      t.bigint :company_id, null: false
      t.bigint :location_id
      t.string :conversable_type
      t.bigint :conversable_id
      t.string :channel, null: false, default: 'sms'
      t.bigint :assigned_user_id
      t.datetime :snoozed_until
      # The number we text from, and the buyer's, both E.164. Replies to a shared
      # pool number are routed by this pair, since the number names no dealer.
      t.string :sender_number
      t.string :buyer_phone
      t.boolean :pool, null: false, default: false
      t.string :messaging_service_sid
      # active: the assistant is answering. handed_off: a person is. closed: done.
      t.string :status, null: false, default: 'active'
      t.boolean :assistant_enabled, null: false, default: true
      t.bigint :handed_off_to_user_id
      t.string :handoff_reason
      t.datetime :handed_off_at
      t.jsonb :qualification, null: false, default: {}
      t.integer :unanswered_count, null: false, default: 0
      t.integer :failed_answer_count, null: false, default: 0
      t.datetime :last_inbound_at
      t.datetime :last_outbound_at
      t.datetime :last_message_at
      t.string :last_message_preview
      t.datetime :reply_due_at
      t.datetime :started_at
      t.datetime :ended_at
      t.timestamps
    end

    add_index :conversations, :company_id
    add_index :conversations, [:company_id, :status, :last_message_at]
    add_index :conversations, [:conversable_type, :conversable_id]
    add_index :conversations, :assigned_user_id
    add_index :conversations, [:sender_number, :buyer_phone],
              unique: true, where: "status IN ('active', 'handed_off')",
              name: 'index_conversations_open_by_numbers'

    create_table :conversation_reads do |t|
      t.bigint :conversation_id, null: false
      t.bigint :user_id, null: false
      t.datetime :last_read_at, null: false
      t.timestamps
    end
    add_index :conversation_reads, [:conversation_id, :user_id], unique: true
    add_index :conversation_reads, :user_id
  end
end
