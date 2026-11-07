# frozen_string_literal: true

module Assistant
  # Quinn AI's email replies a rep approves before they go (E96), when the
  # dealer chose "Quinn writes a draft for your team". The draft waits on the
  # conversation; the rep sends it as written, edits it, or throws it away.
  module Drafts
    module_function

    def save!(conversation, subject:, body:, handoff_reason: nil, summary: nil)
      conversation.update_columns(draft_reply: {
        'channel' => 'email', 'subject' => subject.to_s.truncate(150), 'body' => body.to_s,
        'handoff_reason' => handoff_reason, 'summary' => summary.to_s.truncate(400), 'created_at' => Time.current.iso8601
      }.compact, updated_at: Time.current)
      notify(conversation)
    end

    # Sent as Quinn's reply; Quinn keeps the conversation unless its draft
    # said a person should take over.
    def send!(conversation, user:, subject: nil, body: nil)
      draft = conversation.draft_reply.to_h
      raise ArgumentError, 'No draft waiting' if draft.blank?

      text = body.to_s.strip.presence || draft['body']
      result = Assistant::Messenger.email!(conversation, subject: subject.to_s.strip.presence || draft['subject'], body: text,
                                                         approved_by: user)
      conversation.update_columns(draft_reply: nil)
      if draft['handoff_reason'].present?
        Assistant::Handoff.perform!(conversation, reason: draft['handoff_reason'], summary: draft['summary'], buyer_text: nil)
      end
      result
    end

    def discard!(conversation)
      conversation.update_columns(draft_reply: nil)
    end

    def notify(conversation)
      user = Assistant::Handoff.handoff_user(conversation)
      return unless user

      lead = conversation.conversable
      who = [lead.try(:first_name), lead.try(:last_name)].compact_blank.join(' ').presence || 'A buyer'
      NotificationService.create(
        recipient: user, notification_type: :assistant_draft, notifiable: lead, company_id: conversation.company_id,
        message: "#{who} replied by email. #{Assistant::Settings.for(conversation.company).assistant_name} AI wrote an answer for you to check and send.",
        action_url: "/inbox?c=#{conversation.id}", action_text: 'Review the reply', deliver_now: true
      )
    rescue StandardError => e
      Rails.logger.error("[Assistant::Drafts] notify failed: #{e.class}: #{e.message}")
    end
  end
end
