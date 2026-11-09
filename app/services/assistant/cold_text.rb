# frozen_string_literal: true

module Assistant
  # Quinn AI answers a text to the dealer's number that answers nothing we
  # sent (E96, Tom 2026-11-09). ColdTextHandler has already made the lead (or
  # found the record) and threaded the text into the Inbox; this decides
  # whether Quinn takes the conversation, per the dealer's "Texts from new
  # people" choice in Quinn settings:
  #   new    people not yet in the CRM (the default)
  #   leads  also leads already in the CRM who have no conversation open
  #   off    a person answers every one
  #
  # Never a customer (contact) or a conversation a person already has, never a
  # lead that is closed, from a partner with its own AI, or opted out. The
  # person texted first, so a reply about what they asked is expected; the
  # lead is marked as agreeing to texts about their inquiry (not marketing).
  module ColdText
    module_function

    def consider(conversation, cold)
      return false unless conversation && cold
      return false unless takes?(conversation, cold)

      lead = conversation.conversable
      lead.update_columns(sms_inquiry_consent: true, sms_inquiry_consent_at: Time.current) unless lead.sms_inquiry_consent
      conversation.update!(assistant_enabled: true, status: 'active', assigned_user_id: conversation.assigned_user_id || lead.owner_id)
      Assistant::Inbound.received(conversation, cold.communication)
    rescue StandardError => e
      Rails.logger.error("[Assistant::ColdText] conversation #{conversation&.id}: #{e.class}: #{e.message}")
      false
    end

    def takes?(conversation, cold)
      settings = Assistant::Settings.for(conversation.company)
      return false unless settings.enabled?

      choice = settings.cold_texts
      return false if choice == 'off'
      return false unless cold.created_lead || choice == 'leads'

      lead = conversation.conversable
      return false unless lead.is_a?(Lead) && conversation.channel == 'sms' && !conversation.pool?
      # A conversation this text opened, not one a rep is already in.
      return false if conversation.assistant_enabled? || Communication.where(conversation_id: conversation.id).count > 1
      return false if lead.try(:is_converted) == true || Assistant::FollowUp::STOP_STATUSES.include?(lead.status.to_s)
      return false if lead.source&.name.to_s.match?(Assistant::Starter::PARTNER_AI_SOURCE)

      !CommunicationOptOut.check(channel: 'sms', company: lead.company, record: lead, address: conversation.buyer_phone).opted_out?
    end
  end
end
