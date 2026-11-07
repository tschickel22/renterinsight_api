# frozen_string_literal: true

# Quinn sends the first text to a new lead itself (E96, Tom 2026-11-07), so a
# dealer does not need a play that texts new leads for Quinn to start.
#
# Runs two minutes after the lead arrives, which lets a play that does text
# new leads go first: if anything was texted to the lead by then (a play or a
# person), or the buyer is already talking in the website chat, Quinn sends
# nothing. Only leads that came in by themselves (a form, Facebook, the API),
# never imports or leads a rep typed in.
class AssistantStartJob < ApplicationJob
  queue_as :default

  WAIT = 2.minutes
  ORIGINS = [Lead::ORIGIN_INTAKE_FORM, Lead::ORIGIN_API, Lead::ORIGIN_FACEBOOK, 'partner_api', 'facebook_lead_ads'].freeze
  # A lead older than this is not new; a job held up in a queue must not text it.
  FRESH_FOR = 2.hours

  # Cheap checks before a job is queued at all (called from Lead after create).
  def self.consider(lead)
    return unless ORIGINS.include?(lead.origin.to_s) && lead.phone.present? && lead.may_text_about_inquiry
    return unless Assistant::Settings.for(lead.company).auto_start?

    set(wait: WAIT).perform_later(lead.id)
  rescue StandardError => e
    Rails.logger.warn("[AssistantStartJob] could not queue for lead #{lead&.id}: #{e.message}")
  end

  def perform(lead_id)
    lead = Lead.find_by(id: lead_id)
    return unless lead && lead.created_at > FRESH_FOR.ago
    return unless Assistant::Settings.for(lead.company).auto_start?

    starter = Assistant::Starter.for(lead)
    return log(lead, 'already in a conversation') if starter.existing
    return log(lead, 'not eligible') unless starter.eligible?
    return log(lead, 'no number to text from') unless starter.sender
    return log(lead, 'already texted') if already_texted?(lead)
    return log(lead, 'talking in the website chat') if chatting?(lead)

    conversation = starter.open!
    settings = Assistant::Settings.for(lead.company)
    brain = Assistant::Brain.new(conversation: conversation, settings: settings, history: [], opener: true)
    result = brain.call
    body = Assistant::Rules.tidy(result.reply)
    problem = Assistant::Rules.violation(body, allowed_urls: brain.allowed_urls)
    body = fallback(lead, settings) if problem
    body = "#{body} Reply STOP to opt out." unless body.match?(/\bSTOP\b/)
    starter.send_first_text!(body: body, sent_by: 'assistant', metadata: { quinn_opener: true })
    log(lead, "sent (#{problem ? "fallback, #{problem}" : 'written'})")
  rescue StandardError => e
    Rails.logger.error("[AssistantStartJob] lead #{lead_id}: #{e.class}: #{e.message}")
  end

  private

  def already_texted?(lead)
    Communication.where(communicable: lead, channel: 'sms', direction: 'outbound').exists?
  end

  def chatting?(lead)
    Conversation.where(conversable: lead, channel: 'web_chat')
                .joins(:chat_messages).where(chat_messages: { direction: 'inbound' }).exists?
  end

  # When the model's draft breaks a rule: plain, safe, and still a question.
  def fallback(lead, settings)
    first = lead.first_name.to_s.strip
    "Hi#{" #{first}" if first.present? && !first.match?(Assistant::Learn::PLACEHOLDER_NAME)}, this is " \
      "#{settings.assistant_name} with #{lead.company.name}. Thanks for asking about our homes. " \
      'What are you hoping to find?'
  end

  def log(lead, what)
    Rails.logger.info("[AssistantStartJob] lead #{lead.id}: #{what}")
  end
end
