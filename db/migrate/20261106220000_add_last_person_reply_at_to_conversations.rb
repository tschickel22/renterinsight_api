# frozen_string_literal: true

# When a person last answered in the conversation (E96 inbox). "Needs you" is a
# buyer message newer than this on a conversation the assistant is not handling.
class AddLastPersonReplyAtToConversations < ActiveRecord::Migration[8.0]
  def change
    add_column :conversations, :last_person_reply_at, :datetime
  end
end
