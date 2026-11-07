# frozen_string_literal: true

# Quinn AI's email reply waiting for a rep to approve (E96, 2026-11-07), when
# the dealer chose "Quinn writes a draft". Additive only.
class AddDraftReplyToConversations < ActiveRecord::Migration[8.0]
  def change
    add_column :conversations, :draft_reply, :jsonb
  end
end
