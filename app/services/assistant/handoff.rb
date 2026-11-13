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
      'visit_time' => 'picked a time to visit; confirm it',
      'ready_to_buy' => 'says they are ready to buy',
      'long_conversation' => 'has written a lot; worth a person now',
      'ready_for_rep' => 'is ready to talk with the team',
      'unsure' => 'asked something the assistant could not answer',
      'rule_check' => 'the assistant could not write a safe answer',
      'email_reply' => 'replied by email',
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
      # A person has it: Quinn's follow-ups stop until it is handed back.
      Assistant::FollowUp.schedule!(conversation)

      text = buyer_text == :default ? default_buyer_text(user, conversation) : buyer_text
      Assistant::Messenger.deliver!(conversation, body: text) if text.present?

      notify(conversation, user, reason, summary)
      user
    end

    # A person texted in the conversation: they have it now. No notice needed.
    def taken_over!(conversation, user)
      conversation.update!(status: 'handed_off', handoff_reason: 'rep_replied', handed_off_at: Time.current,
                           handed_off_to_user_id: user.id, assigned_user_id: conversation.assigned_user_id || user.id)
      Assistant::FollowUp.schedule!(conversation)
    end

    def hand_back!(conversation)
      conversation.update!(status: 'active', handoff_reason: nil, handed_off_at: nil, handed_off_to_user_id: nil,
                           failed_answer_count: 0, assistant_enabled: true)
      # Handing back restarts Quinn's long-term follow-ups from today.
      Assistant::FollowUp.restart!(conversation)
    end

    def handoff_user(conversation)
      settings = Assistant::Settings.for(conversation.company)
      users = conversation.company.users
      chosen = users.find_by(id: settings['handoff_user_id']) if settings['handoff_mode'] == 'user'
      chosen ||= users.find_by(id: conversation.conversable.try(:owner_id))
      chosen ||= users.find_by(id: conversation.assigned_user_id)
      # A website chat whose lead has no owner (or, after an error, no lead):
      # the next rep in the rotation of the form chat leads go through, as a
      # lead from that form would get (Tom, 2026-11-12). Not the company's
      # first admin, which sent every such chat to one person.
      chosen ||= rotation_user(conversation) if conversation.web_chat?
      # Last resort, only for a company with no usable form: someone must see it.
      chosen ||= users.active.select(&:effective_admin?).reject(&:platform_admin?).min_by(&:id) if conversation.web_chat?
      chosen
    end

    def rotation_user(conversation)
      form = Concierge::LeadCapture.new(company: conversation.company).form
      id = form&.next_owner_id
      id && conversation.company.users.active.find_by(id: id)
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Handoff] rotation failed for conversation #{conversation.id}: #{e.message}")
      nil
    end

    def default_buyer_text(user, conversation = nil)
      first = user&.try(:first_name).presence
      if conversation&.web_chat?
        who = first || 'our team'
        lead = conversation.conversable
        # Only ask for a way to reach them when the chat does not have one yet.
        if lead.try(:email).present? || lead.try(:phone).present?
          return "I have asked #{who} to join this chat. If you need to go, #{first ? first : 'we'} will follow up with you."
        end
        return "I have asked #{who} to join this chat. If you need to go, leave your name and an email or mobile number and we will follow up."
      end
      first ? "I have asked #{first} to text you directly." : 'I have asked our team to text you directly.'
    end

    def notify(conversation, user, reason, summary)
      return unless user

      lead = conversation.conversable
      who = lead.try(:display_name).presence || [lead.try(:first_name), lead.try(:last_name)].compact_blank.join(' ').presence ||
            conversation.buyer_phone.presence || 'A website visitor'
      message = "#{who} #{REASON_LABELS.fetch(reason.to_s, 'needs a person')}."
      message += ' They are in the website chat now.' if conversation.visitor_on_page?
      message += " #{summary}" if summary.present?
      NotificationService.create(
        recipient: user, notification_type: :assistant_handoff, notifiable: lead,
        message: message.truncate(300), company_id: conversation.company_id, action_text: 'Open conversation',
        # The Inbox thread, which works on a phone: the rep answers from there,
        # on the conversation's number. Texted to the mobile number in their
        # account settings when that notification is on (default on).
        action_url: "/inbox?c=#{conversation.id}",
        # Without this NotificationService only saves it (in-app and push);
        # email and the text to the rep's phone go out only when asked.
        deliver_now: true
      )
    rescue StandardError => e
      Rails.logger.error("[Assistant::Handoff] notify failed: #{e.class}: #{e.message}")
    end
  end
end
