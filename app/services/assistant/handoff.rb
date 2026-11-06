# frozen_string_literal: true

module Assistant
  # Passes a conversation from the assistant to a person, and back (E96).
  module Handoff
    REASON_LABELS = {
      'asked_for_person' => 'asked for a person',
      'upset' => 'sounds unhappy',
      'finance_or_credit' => 'asked about payments or credit',
      'legal_or_warranty' => 'asked about legal, warranty or a complaint',
      'trade_in_value' => 'wants a trade in valued',
      'appointment' => 'wants to set a time to visit',
      'unsure' => 'asked something the assistant could not answer',
      'rule_check' => 'the assistant could not write a safe answer',
      'error' => 'the assistant hit an error',
      'other' => 'needs a person'
    }.freeze

    module_function

    # The assistant decides a person should take over. Tells the buyer (unless
    # the assistant's own reply already did) and the rep.
    def perform!(conversation, reason:, summary: nil, buyer_text: :default)
      user = handoff_user(conversation)
      conversation.update!(
        status: 'handed_off', handoff_reason: reason, handed_off_at: Time.current,
        handed_off_to_user_id: user&.id, assigned_user_id: conversation.assigned_user_id || user&.id
      )

      text = buyer_text == :default ? default_buyer_text(user) : buyer_text
      Assistant::Messenger.deliver!(conversation, body: text) if text.present?

      notify(conversation, user, reason, summary)
      user
    end

    # A person texted in the conversation: they have it now. No notice needed.
    def taken_over!(conversation, user)
      conversation.update!(status: 'handed_off', handoff_reason: 'rep_replied', handed_off_at: Time.current,
                           handed_off_to_user_id: user.id, assigned_user_id: conversation.assigned_user_id || user.id)
    end

    def hand_back!(conversation)
      conversation.update!(status: 'active', handoff_reason: nil, handed_off_at: nil, handed_off_to_user_id: nil,
                           failed_answer_count: 0, assistant_enabled: true)
    end

    def handoff_user(conversation)
      settings = Assistant::Settings.for(conversation.company)
      users = conversation.company.users
      chosen = users.find_by(id: settings['handoff_user_id']) if settings['handoff_mode'] == 'user'
      chosen ||= users.find_by(id: conversation.conversable.try(:owner_id))
      chosen ||= users.find_by(id: conversation.assigned_user_id)
      chosen
    end

    def default_buyer_text(user)
      first = user&.try(:first_name).presence
      first ? "I have asked #{first} to text you directly." : 'I have asked our team to text you directly.'
    end

    def notify(conversation, user, reason, summary)
      return unless user

      lead = conversation.conversable
      who = lead.try(:display_name).presence || [lead.try(:first_name), lead.try(:last_name)].compact_blank.join(' ').presence ||
            conversation.buyer_phone
      message = "#{who} #{REASON_LABELS.fetch(reason.to_s, 'needs a person')}."
      message += " #{summary}" if summary.present?
      NotificationService.create(
        recipient: user, notification_type: :assistant_handoff, notifiable: lead,
        message: message.truncate(300), company_id: conversation.company_id, action_text: 'Open conversation',
        # The Inbox thread, which works on a phone: the rep answers from there,
        # on the conversation's number. Texted to the mobile number in their
        # account settings when that notification is on (default on).
        action_url: "/inbox?c=#{conversation.id}"
      )
    rescue StandardError => e
      Rails.logger.error("[Assistant::Handoff] notify failed: #{e.class}: #{e.message}")
    end
  end
end
