# frozen_string_literal: true

# When a person last read a conversation, for the inbox unread mark (E96).
class ConversationRead < ApplicationRecord
  belongs_to :conversation
  belongs_to :user
end
