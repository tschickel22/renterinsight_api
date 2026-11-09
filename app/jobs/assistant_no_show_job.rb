# frozen_string_literal: true

# A customer missed their visit (a rep marked it No show): an hour later Quinn
# AI texts them kindly with two new times, and books the one they pick (E96
# phase 2). Only for a lead or contact Quinn may text, and only when nothing
# else was booked since.
class AssistantNoShowJob < ApplicationJob
  queue_as :default

  WAIT = 1.hour

  def perform(activity_class, activity_id)
    activity = activity_class.to_s.safe_constantize&.find_by(id: activity_id)
    return unless activity&.status == 'no_show'

    record = ::Appointments::Customer.for(activity)&.record
    return unless record.is_a?(Lead)
    return if Assistant::Appointments.upcoming_for(record, limit: 1).any?

    starter = Assistant::Starter.for(record)
    return log(activity, 'Quinn cannot text this lead') unless starter.takes_over?

    settings = Assistant::Settings.for(record.company)
    # Not in the dealer's quiet hours: try again in an hour.
    if Assistant::Rules.quiet_now?(settings, record.try(:location))
      self.class.set(wait: 1.hour).perform_later(activity_class, activity_id)
      return log(activity, 'quiet hours, later')
    end

    conversation = starter.existing || starter.open!
    # The rep marked it, so they want Quinn to win the visit back.
    Assistant::Handoff.hand_back!(conversation) unless conversation.assistant_answering?
    booking = Assistant::Booking.new(conversation)
    missed = ::Appointments::TimeText.for(activity, record.company)
    brain = Assistant::Brain.new(conversation: conversation, settings: settings, history: conversation.history(Assistant::Brain::HISTORY),
                                 booking: booking, missed_visit: missed, purpose: 'no_show')
    result = brain.call
    body = Assistant::Rules.tidy(result.reply)
    if Assistant::Rules.violation(body, allowed_urls: brain.allowed_urls)
      times = booking.slots.first(2).map(&:label)
      body = "No problem about #{missed.split(' at ').first}, things come up. " +
             (times.size == 2 ? "Would #{times[0]} or #{times[1]} work instead?" : 'Would you like to pick a new time?')
    end
    Assistant::Messenger.deliver!(conversation, body: body, sent_by: 'assistant', extra_metadata: { quinn_no_show: activity.id })
    # Then Quinn's follow-ups take over from today, aimed at a new visit, for
    # as long as the dealer's follow-up plan runs (the nurture after a no-show).
    Assistant::FollowUp.restart!(conversation.reload)
    log(activity, 'texted')
  rescue StandardError => e
    Rails.logger.error("[AssistantNoShowJob] #{activity_class} #{activity_id}: #{e.class}: #{e.message}")
  end

  private

  def log(activity, what)
    Rails.logger.info("[AssistantNoShowJob] #{activity.class.name} #{activity.id}: #{what}")
  end
end
