# frozen_string_literal: true

module Assistant
  # A buyer texted into a conversation (backlog E96).
  module Inbound
    # Seconds before the assistant answers: long enough that it reads like a
    # person and that three quick texts get one answer, short enough to beat
    # every other dealer the buyer asked.
    DELAY = (20..45)

    module_function

    # Returns true when the assistant will answer, so the caller does not also
    # forward the message to a rep.
    def received(conversation, communication, keyword: false)
      conversation.note_message!(communication)
      return false if keyword || !conversation.assistant_answering?
      return false unless Assistant::Settings.for(conversation.company).enabled?

      due = Time.current + rand(DELAY).seconds
      # A reply already waiting moves later, never earlier, so the job for the
      # newest text is the one that answers and the earlier ones step aside.
      pending = conversation.reply_due_at
      due = pending + 1.second if pending && pending.future? && pending >= due
      conversation.update_columns(reply_due_at: due, updated_at: Time.current)
      AssistantReplyJob.set(wait_until: due).perform_later(conversation.id, due.to_f)
      true
    rescue StandardError => e
      Rails.logger.error("[Assistant::Inbound] #{e.class}: #{e.message}")
      false
    end
  end
end
