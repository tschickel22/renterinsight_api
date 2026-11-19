# frozen_string_literal: true

module Outreach
  # Someone answered an outreach message (backlog E105).
  module Inbound
    DELAY = (30..90)
    STOP_WORDS = %w[STOP STOPALL UNSUBSCRIBE CANCEL END QUIT].freeze

    module_function

    def target_for(conversation)
      return nil unless conversation

      OutreachTarget.where(conversation_id: conversation.id).order(:id).last
    end

    def owns?(conversation)
      target_for(conversation).present?
    end

    # True when outreach will answer, so nobody is notified twice.
    def received(conversation, communication, keyword: false)
      target = target_for(conversation)
      conversation.note_message!(communication)
      target.record!('replied', channel: communication.channel == 'email' ? 'email' : 'text', communication_id: communication.id)
      target.update!(first_reply_at: target.first_reply_at || Time.current, next_touch_at: nil)
      target.update!(status: 'replied') if target.status == 'sent'

      text = communication.body.to_s.strip.upcase
      return stopped(target) if STOP_WORDS.include?(text)
      return false if keyword && !%w[YES START].include?(text)
      return false unless conversation.assistant_answering?

      unless Settings.for(conversation.company).active?
        Handoff.perform!(target, reason: 'unsure', summary: 'Outreach is off, so this reply needs you.')
        return true
      end

      schedule(conversation)
      true
    rescue StandardError => e
      Rails.logger.error("[Outreach::Inbound] conversation #{conversation&.id}: #{e.class}: #{e.message}")
      false
    end

    def stopped(target)
      target.record!('unsubscribed') unless target.recorded?('unsubscribed')
      target.stop!('opted out')
      true
    end

    def schedule(conversation)
      lead = conversation.conversable
      company = conversation.company
      due = Time.current + rand(DELAY).seconds
      due = Clock.next_reply_time(lead, company) unless Clock.reply_now?(lead, company, at: due)
      pending = conversation.reply_due_at
      due = [due, pending + 1.second].max if pending&.future?
      conversation.update_columns(reply_due_at: due, updated_at: Time.current)
      OutreachReplyJob.set(wait_until: due).perform_later(conversation.id, due.to_f)
    end
  end
end
