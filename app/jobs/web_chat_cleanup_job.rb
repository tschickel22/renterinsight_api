# frozen_string_literal: true

# Closes website chats nobody needs to look at again (E96): ones Quinn handled
# that have been quiet a day, and greetings no visitor ever answered. A chat a
# person has (handed off) stays open for them.
class WebChatCleanupJob < ApplicationJob
  queue_as :default

  def perform
    base = Conversation.where(channel: 'web_chat', status: 'active')
    quiet = base.where.not(last_inbound_at: nil).where('last_message_at < ?', 24.hours.ago)
    unanswered = base.where(last_inbound_at: nil).where('created_at < ?', 6.hours.ago)
    [quiet, unanswered].each { |scope| scope.update_all(status: 'closed', ended_at: Time.current, updated_at: Time.current) }
  end
end
