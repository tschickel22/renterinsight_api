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

    # The open conversation with this person on any channel, newest first:
    # the Inbox keeps one row per person, and the thread shows every channel.
    # Texts and email only: a website chat lives in its own thread, and email
    # threaded into it would never reach the visitor's widget.
    def open_conversation_for_record(record)
      Conversation.open_now.where(conversable: record).where.not(channel: 'web_chat').order(updated_at: :desc).first
    end

    # An email in or out on a lead or contact (Communication callback).
    # In: a reply to something we sent (tracked reply-to address or a
    # campaign), never an out-of-office, a BCC copy or a synced mailbox. Out:
    # only a person's own email; automated mail does not count as an answer.
    def track_email!(communication)
      meta = communication.metadata.to_h
      record = communication.communicable
      company_id = communication.company_id || record.try(:company_id)
      return nil if record.nil? || company_id.nil?

      if communication.direction == 'inbound'
        return nil unless meta['reply_tracking_token'].present? || meta['campaign_send_id'].present?
        return nil if meta['is_ooo'] == true || meta['is_ooo'] == 'true'

        conversation = open_conversation_for_record(record) || Conversation.create!(
          company_id: company_id, location_id: record.try(:location_id), conversable: record, channel: 'email',
          assigned_user_id: record.try(:owner_id), status: 'active', assistant_enabled: false, started_at: Time.current
        )
        communication.update_columns(conversation_id: conversation.id)
        conversation.note_message!(communication)
        # The assistant texts; an email needs a person. The rep is already told
        # by InboundEmail::ReplyNotifier, so no second notice.
        if conversation.assistant_answering?
          conversation.update!(status: 'handed_off', handoff_reason: 'email_reply', handed_off_at: Time.current,
                               handed_off_to_user_id: conversation.assigned_user_id)
        end
        conversation
      else
        person = meta['sender_user_id'].presence || communication.try(:user_id)
        return nil if person.blank? || meta['campaign_send_id'].present?

        conversation = open_conversation_for_record(record)
        return nil unless conversation

        communication.update_columns(conversation_id: conversation.id)
        conversation.note_message!(communication)
        conversation.update_columns(last_person_reply_at: communication.created_at || Time.current)
        conversation
      end
    rescue StandardError => e
      Rails.logger.error("[Assistant::Threading] email tracking failed: #{e.class}: #{e.message}")
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
