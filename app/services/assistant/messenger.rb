# frozen_string_literal: true

module Assistant
  # Sends a text on a conversation (backlog E96): from the dealer's own number,
  # or from the pool number the conversation runs on. Always through
  # CommunicationService, so opt-outs, caps, usage logs and the thread view all
  # work as for any other text.
  module Messenger
    SOURCES = { 'assistant' => 'assistant', 'play' => 'sequence' }.freeze

    module_function

    # sent_by: 'assistant', 'play' (a play's own text), or 'user' with a user.
    def deliver!(conversation, body:, sent_by: 'assistant', user: nil, extra_metadata: {}, media_urls: [])
      return deliver_chat!(conversation, body: body, sent_by: sent_by, user: user, extra_metadata: extra_metadata) if conversation.web_chat?

      lead = conversation.conversable
      raise ArgumentError, 'conversation has no buyer record' unless lead

      if CommunicationOptOut.check(channel: 'sms', company: conversation.company, record: lead,
                                   address: conversation.buyer_phone).opted_out?
        conversation.update!(status: 'closed', ended_at: Time.current, handoff_reason: 'opted_out')
        return { success: false, error: 'opted_out' }
      end

      # The assistant's and plays' words follow house style; a person's are sent as typed.
      body = Assistant::Rules.tidy(body) unless sent_by == 'user'
      body = pool_prefix(conversation) + body if conversation.pool? && !body.start_with?(pool_prefix(conversation))

      # Symbol keys: CommunicationService fills in :source with ||=, so a string
      # 'source' key was overwritten with 'manual'.
      metadata = (extra_metadata || {}).to_h.symbolize_keys.merge(
        sent_by: sent_by, conversation_id: conversation.id, source: SOURCES.fetch(sent_by, 'manual')
      )
      media = Array(media_urls).first(Assistant::Media::MAX_PHOTOS)
      metadata[:media_urls] = media if media.any?
      CommunicationService.send_sms(
        communicable: lead, to: conversation.buyer_phone, from: conversation.sender_number, body: body,
        metadata: metadata, sender_user_id: user&.id, user: user, conversation: conversation, media_urls: media
      )
    end

    # A website chat: the message is stored and the visitor's widget picks it
    # up on its next check (every few seconds while open).
    def deliver_chat!(conversation, body:, sent_by:, user:, extra_metadata: {})
      body = Assistant::Rules.tidy(body) unless sent_by == 'user'
      extra = (extra_metadata || {}).to_h.stringify_keys
      who = { 'user' => 'user', 'system' => 'system' }.fetch(sent_by.to_s, 'assistant')
      message = conversation.chat_messages.create!(
        company_id: conversation.company_id, direction: 'outbound', body: body, sent_by: who, user_id: user&.id,
        listings: Array(extra['listings']), actions: Array(extra['actions'])
      )
      conversation.note_message!(message)
      conversation.update_columns(last_person_reply_at: message.created_at) if who == 'user'
      { success: true, chat_message: message }
    end

    def dealer_name(conversation)
      conversation.company.name.to_s
    end

    # Every text on a shared number names the dealer and the platform, as the
    # pool campaign was registered ("Summit Park Homes via DealerTide: ...").
    def pool_prefix(conversation)
      "#{dealer_name(conversation)} via #{Brand.current.name}: "
    end
  end
end
