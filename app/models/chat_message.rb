# frozen_string_literal: true

# One message in a website chat (E96). Quinn's, a rep's from the Inbox, or the
# visitor's. Same shape the Brain reads from a text (direction, body).
class ChatMessage < ApplicationRecord
  DIRECTIONS = %w[inbound outbound].freeze
  SENDERS = %w[visitor assistant user system].freeze

  belongs_to :conversation
  belongs_to :user, optional: true

  validates :direction, inclusion: { in: DIRECTIONS }
  validates :body, presence: true

  before_validation { self.company_id ||= conversation&.company_id }

  def as_chat_json
    { id: id, role: direction == 'inbound' ? 'user' : 'assistant', content: body, sent_by: sent_by,
      from_person: sent_by == 'user', listings: listings, actions: actions, at: created_at&.iso8601 }
  end
end
