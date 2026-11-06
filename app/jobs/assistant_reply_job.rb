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
    conversation.merge_qualification!(result.qualification) if result.qualification.present?
    copy_onto_lead(conversation, result.qualification)

    reason = result.handoff ? result.handoff_reason : nil
    reply = Assistant::Rules.tidy(result.reply)
    problem = Assistant::Rules.violation(reply)

    if problem && !result.handoff
      retry_result = draft(conversation, settings, feedback: problem)
      reply = Assistant::Rules.tidy(retry_result.reply)
      problem = Assistant::Rules.violation(reply)
      result = retry_result
      reason = retry_result.handoff ? retry_result.handoff_reason : nil
    end

    if problem
      Assistant::Handoff.perform!(conversation, reason: reason || 'rule_check', summary: result.summary)
    elsif reason
      # The reply already tells the buyer someone will text them.
      Assistant::Messenger.deliver!(conversation, body: reply) if reply.present?
      Assistant::Handoff.perform!(conversation, reason: reason, summary: result.summary,
                                                buyer_text: reply.present? ? nil : :default)
    else
      Assistant::Messenger.deliver!(conversation, body: reply)
    end
  rescue StandardError => e
    Rails.logger.error("[AssistantReplyJob] conversation #{conversation_id}: #{e.class}: #{e.message}")
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
    history = Communication.where(conversation_id: conversation.id, channel: 'sms').order(:created_at).last(Assistant::Brain::HISTORY)
    result = Assistant::Brain.new(conversation: conversation, settings: settings, history: history, feedback: feedback).call
    Rails.logger.info("[AssistantReplyJob] conversation #{conversation.id} model=#{result.usage[:model]} " \
                      "in=#{result.usage[:input_tokens]} out=#{result.usage[:output_tokens]} handoff=#{result.handoff}")
    result
  end

  # What the buyer told the assistant, on the lead where the lead has a place
  # for it. Only blank fields are filled, so nothing a rep typed is overwritten.
  LEAD_FIELDS = { 'bedrooms' => :preferred_bedrooms, 'budget' => :budget_range,
                  'timeline' => :purchase_timeframe }.freeze

  def copy_onto_lead(conversation, fields)
    lead = conversation.conversable
    return if lead.nil? || fields.blank?

    changes = LEAD_FIELDS.each_with_object({}) do |(key, column), out|
      next unless fields[key].present? && lead.has_attribute?(column) && lead[column].blank?

      value = fields[key].to_s
      value = value[/\d+/]&.to_i if column == :preferred_bedrooms
      out[column] = value if value.present?
    end
    lead.update_columns(changes) if changes.any?
  rescue StandardError => e
    Rails.logger.warn("[AssistantReplyJob] could not copy onto lead: #{e.message}")
  end
end
