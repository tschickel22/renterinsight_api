# frozen_string_literal: true

# Tells open Inboxes that a conversation changed, so a new text, email, chat
# message or Quinn AI reply shows without waiting for the next refresh (E96).
# Streams the signed-in person's own company only; the payload is an id, and
# the page fetches what it may see through the normal API.
class InboxChannel < ApplicationCable::Channel
  def subscribed
    return reject unless current_user&.company_id

    stream_from self.class.stream_for_company(current_user.company_id)
  end

  def self.stream_for_company(company_id)
    "inbox_company_#{company_id}"
  end

  def self.changed(conversation)
    ActionCable.server.broadcast(stream_for_company(conversation.company_id), { conversation_id: conversation.id })
  rescue StandardError => e
    Rails.logger.warn("[InboxChannel] broadcast failed: #{e.class}: #{e.message}")
  end
end
