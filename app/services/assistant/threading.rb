# frozen_string_literal: true

module Assistant
  # Keeps texts attached to their conversation (backlog E96).
  module Threading
    module_function

    def open_conversation_for(communicable, to)
      return nil if communicable.nil? || to.blank?

      phone = Conversation.normalize_phone(to)
      Conversation.open_now.where(conversable: communicable, buyer_phone: phone, channel: 'sms')
                  .order(updated_at: :desc).first
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Threading] lookup failed: #{e.class}: #{e.message}")
      nil
    end

    # A person texting in the conversation takes it over from the assistant.
    def outbound_sent(conversation, communication, sender_user_id: nil)
      conversation.note_message!(communication)
      by_assistant = %w[assistant play].include?(communication.metadata.to_h['sent_by'])
      if by_assistant
        conversation.increment!(:unanswered_count)
      elsif sender_user_id.present? && conversation.assistant_answering?
        user = conversation.company.users.find_by(id: sender_user_id)
        Assistant::Handoff.taken_over!(conversation, user) if user
      end
    rescue StandardError => e
      Rails.logger.error("[Assistant::Threading] outbound bookkeeping failed: #{e.class}: #{e.message}")
    end
  end
end
