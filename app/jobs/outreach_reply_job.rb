# frozen_string_literal: true

# Answers someone who wrote back to Proactive Outreach (backlog E105). A newer
# message moves reply_due_at on, so several quick texts get one answer.
class OutreachReplyJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, due = nil)
    conversation = Conversation.find_by(id: conversation_id)
    return unless conversation
    return if due && conversation.reply_due_at && conversation.reply_due_at.to_f > due.to_f + 0.5

    Outreach::Responder.new(conversation).call
  end
end
