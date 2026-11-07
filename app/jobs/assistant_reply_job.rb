# frozen_string_literal: true

# Writes and sends the Lead Assistant's answer to a buyer's text (backlog E96).
# Never run inside the webhook: Twilio waits on that request, and a model call
# can take seconds.
class AssistantReplyJob < ApplicationJob
  queue_as :default

  # due: the reply_due_at this job was scheduled for. A newer buyer text moves
  # reply_due_at on and schedules its own job, so this one steps aside and the
  # buyer gets one answer to several quick texts.
  def perform(conversation_id, due = nil)
    conversation = Conversation.find_by(id: conversation_id)
    return unless conversation&.assistant_answering?
    return if due && conversation.reply_due_at && conversation.reply_due_at.to_f > due.to_f + 0.5

    settings = Assistant::Settings.for(conversation.company)
    return unless settings.enabled?
    return if conversation.unanswered_count >= Assistant::Rules::MAX_UNANSWERED

    result = draft(conversation, settings)
    Assistant::Learn.apply!(conversation, result)

    reason = result.handoff ? result.handoff_reason : nil
    reply = Assistant::Rules.tidy(result.reply)
    problem = Assistant::Rules.violation(reply, allowed_urls: @allowed_urls)

    if problem && !result.handoff
      retry_result = draft(conversation, settings, feedback: problem)
      Assistant::Learn.copy_contact(conversation.conversable, retry_result.contact)
      reply = Assistant::Rules.tidy(retry_result.reply)
      problem = Assistant::Rules.violation(reply, allowed_urls: @allowed_urls)
      result = retry_result
      reason = retry_result.handoff ? retry_result.handoff_reason : nil
    end

    Assistant::Appointments.resend_invite(conversation.conversable) if result.resend_invite && !problem
    inbound = Communication.where(conversation_id: conversation.id, direction: 'inbound').order(:id).last
    Assistant::Learn.record_question(conversation, result, reason, problem, communication_id: inbound&.id)

    if problem
      Assistant::Handoff.perform!(conversation, reason: reason || 'rule_check', summary: result.summary)
    elsif reason
      # The reply already tells the buyer someone will text them.
      Assistant::Messenger.deliver!(conversation, body: reply, media_urls: photos_for(conversation, result)) if reply.present?
      Assistant::Handoff.perform!(conversation, reason: reason, summary: result.summary,
                                                buyer_text: reply.present? ? nil : :default)
    else
      Assistant::Messenger.deliver!(conversation, body: reply, media_urls: photos_for(conversation, result))
    end
  rescue StandardError => e
    Rails.logger.error("[AssistantReplyJob] conversation #{conversation_id}: #{e.class}: #{e.message} #{e.backtrace.first(4).join(" | ")}")
    if conversation&.assistant_answering?
      begin
        Assistant::Handoff.perform!(conversation, reason: 'error', summary: nil, buyer_text: nil)
      rescue StandardError
        nil
      end
    end
  end

  private

  def draft(conversation, settings, feedback: nil)
    history = conversation.history(Assistant::Brain::HISTORY)
    brain = Assistant::Brain.new(conversation: conversation, settings: settings, history: history, feedback: feedback)
    result = brain.call
    @allowed_urls = brain.allowed_urls
    Rails.logger.info("[AssistantReplyJob] conversation #{conversation.id} model=#{result.usage[:model]} " \
                      "in=#{result.usage[:input_tokens]} out=#{result.usage[:output_tokens]} handoff=#{result.handoff}")
    result
  end

  # Up to three photos of the home Quinn chose, sent with its reply.
  def photos_for(conversation, result)
    return [] unless result.photo_home_id

    vehicle = conversation.company.vehicles.find_by(id: result.photo_home_id)
    vehicle ? Assistant::Media.photos(vehicle) : []
  end
end
