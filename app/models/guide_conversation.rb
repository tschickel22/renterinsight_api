# frozen_string_literal: true

# A help assistant thread. messages is a list of
# { 'role' => 'user'|'assistant', 'content' => text, 'at' => iso8601, ... }
# with the assistant's citations and suggested places kept beside its text.
class GuideConversation < ApplicationRecord
  MAX_MESSAGES = 40

  belongs_to :user
  belongs_to :company

  def append(message)
    self.messages = (Array(messages) + [message.deep_stringify_keys]).last(MAX_MESSAGES)
  end
end
