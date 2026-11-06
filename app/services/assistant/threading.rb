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

    # A text from a buyer who is not in an assistant conversation still belongs
    # in the inbox: find or start a conversation a person handles.
    def track_inbound!(company:, record:, communication:, our_number:, buyer_number:)
      return nil if company.nil? || record.nil?

      conversation = open_conversation_for(record, buyer_number) ||
                     Conversation.open_for_numbers(sender_number: our_number, buyer_phone: buyer_number)
      conversation ||= Conversation.create!(
        company_id: company.id, location_id: record.try(:location_id), conversable: record, channel: 'sms',
        assigned_user_id: record.try(:owner_id), sender_number: our_number, buyer_phone: buyer_number,
        pool: false, status: 'active', assistant_enabled: false, started_at: Time.current
      )
      communication.update_columns(conversation_id: conversation.id)
      conversation.note_message!(communication)
      conversation
    rescue ActiveRecord::RecordNotUnique
      Conversation.open_for_numbers(sender_number: our_number, buyer_phone: buyer_number)
    rescue StandardError => e
      Rails.logger.error("[Assistant::Threading] inbox tracking failed: #{e.class}: #{e.message}")
      nil
    end

    # A person texting in the conversation takes it over from the assistant.
    def outbound_sent(conversation, communication, sender_user_id: nil)
      conversation.note_message!(communication)
      by_assistant = %w[assistant play].include?(communication.metadata.to_h['sent_by'])
      if by_assistant
        conversation.increment!(:unanswered_count)
      elsif sender_user_id.present?
        conversation.update_columns(last_person_reply_at: communication.created_at || Time.current)
        user = conversation.company.users.find_by(id: sender_user_id)
        Assistant::Handoff.taken_over!(conversation, user) if user && conversation.assistant_answering?
      end
    rescue StandardError => e
      Rails.logger.error("[Assistant::Threading] outbound bookkeeping failed: #{e.class}: #{e.message}")
    end
  end
end
