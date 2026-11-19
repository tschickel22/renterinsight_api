# frozen_string_literal: true

module Outreach
  # Answers someone who wrote back (backlog E105). Asking whether this is AI, and
  # asking to be left alone, are answered in code rather than left to the model.
  class Responder
    def initialize(conversation)
      @conversation = conversation
      @target = Inbound.target_for(conversation)
      @company = conversation.company
      @settings = Settings.for(@company)
      @inbound = Communication.where(conversation_id: conversation.id, direction: 'inbound').order(:id).last
    end

    def call
      return unless @target && @inbound && @conversation.assistant_answering? && @settings.active?

      text = ActionView::Base.full_sanitizer.sanitize(@inbound.body.to_s)
      return wants_out if Guard.wants_out?(text)
      return asks_if_ai if Guard.asks_if_ai?(text)

      answer
    rescue StandardError => e
      Rails.logger.error("[Outreach::Responder] conversation #{@conversation.id}: #{e.class}: #{e.message}")
      Handoff.perform!(@target, reason: 'error', summary: 'Outreach could not write a reply.') if @conversation.reload.assistant_answering?
    end

    private

    def channel
      @inbound.channel == 'email' ? 'email' : 'text'
    end

    def sender
      @sender ||= Sender.new(@target)
    end

    def subject
      base = @inbound.subject.to_s.strip.presence || "Your note to #{@settings['persona_name']}"
      base.match?(/\Are:/i) ? base : "Re: #{base}"
    end

    def wants_out
      sender.deliver!(body: Guard::STOP_ANSWER, channel: channel, kind: 'reply', subject: subject)
      %w[sms email].each do |name|
        CommunicationPreference.find_or_create_for(recipient: @target.lead, channel: name).opt_out!('Asked to stop in a Proactive Outreach conversation')
      end
      @conversation.update!(status: 'closed', ended_at: Time.current, handoff_reason: 'opted_out')
      Inbound.stopped(@target)
    end

    def asks_if_ai
      sender.deliver!(body: Guard.ai_answer(@settings), channel: channel, kind: 'reply', subject: subject)
      Handoff.perform!(@target, reason: 'asked_for_person', summary: 'They asked whether this was AI.')
    end

    def answer
      booking = Booking.new(@conversation)
      result = Writer.new(@target).reply(channel, booking: booking)
      return Handoff.perform!(@target, reason: 'rule_check', summary: result.summary) if result.problem

      body = result.body
      if result.book_slot && (outcome = booking.book!(result.book_slot))
        body = outcome.ok ? Assistant::Booking.combine(body, outcome) : outcome.text.presence || body
        note_booked(outcome.activity) if outcome.ok && outcome.kind == 'booked'
      end
      sender.deliver!(body: body, channel: channel, kind: 'reply', subject: subject, content_item: result.content_item, report: result.share_report)
      Handoff.perform!(@target, reason: result.handoff_reason, summary: result.summary) if result.handoff
      @target.update!(next_touch_at: 3.days.from_now) unless result.handoff || @target.reload.booked_at || @target.status == 'stopped'
    end

    def note_booked(activity)
      @target.update!(status: 'booked', booked_at: Time.current, activity_id: activity.id, next_touch_at: nil)
      @target.record!('booked', metadata: { activity_id: activity.id })
    end
  end
end
