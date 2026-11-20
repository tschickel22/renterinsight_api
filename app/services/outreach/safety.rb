# frozen_string_literal: true

module Outreach
  # The automatic pause (backlog E105). With small waves one event can be a large
  # percentage, so each limit also needs a minimum count, except a spam complaint.
  #
  # Resuming a paused wave acknowledges the problems that paused it. Only problems
  # that come in after that count toward the next pause; the rate is still taken
  # against everything the wave has sent. Without this a resumed wave was paused
  # again on its next tick by the same two unsubscribes (production wave 1,
  # 2026-11-19).
  class Safety
    BOUNCE_RATE = 0.03
    UNSUBSCRIBE_RATE = 0.01
    UNDELIVERED_RATE = 0.20
    MIN_EVENTS = 2
    MIN_UNDELIVERED = 3
    PROBLEM_EVENTS = %w[complained bounced unsubscribed undelivered].freeze
    ACKNOWLEDGED = 'acknowledged_at'

    def self.acknowledge!(wave, user: nil)
      stamp = { ACKNOWLEDGED => Time.current.iso8601, 'acknowledged_by_user_id' => user&.id }.compact
      unacknowledged(wave.outreach_events.where(event_type: PROBLEM_EVENTS)).find_each do |event|
        event.update!(metadata: event.metadata.to_h.merge(stamp).deep_stringify_keys)
      end
    end

    def self.unacknowledged(scope)
      scope.where.not('outreach_events.metadata ? :key', key: ACKNOWLEDGED)
    end

    def initialize(wave)
      @wave = wave
    end

    def problem
      events = @wave.outreach_events
      sent = events.where(event_type: 'sent')
      fresh = self.class.unacknowledged(events)
      return 'a spam complaint came in' if fresh.where(event_type: 'complained').exists?

      emails = sent.where(channel: 'email').count
      texts = sent.where(channel: 'text').count
      bounced = fresh.where(event_type: 'bounced').count
      unsubscribed = fresh.where(event_type: 'unsubscribed').count
      undelivered = fresh.where(event_type: 'undelivered').count
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
