# frozen_string_literal: true

module Outreach
  # The automatic pause (backlog E105). With small waves one event can be a large
  # percentage, so each limit also needs a minimum count, except a spam complaint.
  class Safety
    BOUNCE_RATE = 0.03
    UNSUBSCRIBE_RATE = 0.01
    UNDELIVERED_RATE = 0.20
    MIN_EVENTS = 2
    MIN_UNDELIVERED = 3

    def initialize(wave)
      @wave = wave
    end

    def problem
      events = @wave.outreach_events
      sent = events.where(event_type: 'sent')
      return 'a spam complaint came in' if events.where(event_type: 'complained').exists?

      emails = sent.where(channel: 'email').count
      texts = sent.where(channel: 'text').count
      bounced = events.where(event_type: 'bounced').count
      unsubscribed = events.where(event_type: 'unsubscribed').count
      undelivered = events.where(event_type: 'undelivered').count
      return "#{bounced} emails bounced" if over?(bounced, emails, BOUNCE_RATE, MIN_EVENTS)
      return "#{unsubscribed} people unsubscribed" if over?(unsubscribed, emails + texts, UNSUBSCRIBE_RATE, MIN_EVENTS)
      return "#{undelivered} texts were not delivered" if over?(undelivered, texts, UNDELIVERED_RATE, MIN_UNDELIVERED)

      nil
    end

    private

    def over?(count, total, rate, minimum)
      total.positive? && count >= minimum && count.to_f / total > rate
    end
  end
end
