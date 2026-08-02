# frozen_string_literal: true

module Messaging
  # Hands out evenly spaced send slots for one mailbox.
  #
  # This is the PRIMARY pacing mechanism. Rate limiting cannot be enforced
  # reliably at send time: CampaignSchedulerJob enqueues every due enrollment in
  # batches of 200 and the workers run concurrently, so a check-then-send test
  # races and overshoots by the worker concurrency. Spreading next_send_at when
  # the enrollment is SCHEDULED is single-writer and therefore race-free, and it
  # turns a burst into a queue rather than a rejection.
  #
  # Messaging::ThrottleChecker remains as a runtime backstop for the cases this
  # cannot cover (two campaigns enrolling into one mailbox simultaneously,
  # concurrent advance_to_next_step calls).
  #
  # Stateful on purpose: callers allocate many slots in a loop, so the cursor
  # advances in memory instead of re-querying per recipient.
  class SendPacer
    def initialize(connection_key:, earliest: nil, now: Time.current, limits: nil)
      @connection_key = connection_key.presence
      @now = now
      @earliest = earliest || now
      @rate = limits || Messaging::SendRateLimits.new(connection_key: @connection_key)
      @cursor = nil
    end

    # Seconds between slots. Zero means "no pacing" (unknown mailbox).
    def interval
      @interval ||= @connection_key ? @rate.interval_seconds : 0.0
    end

    def next_slot
      return @earliest if interval.zero?

      @cursor = @cursor.nil? ? first_slot : @cursor + interval
      @cursor
    end

    private

    # Start after whatever this mailbox already has queued, so a second campaign
    # enrolling into the same mailbox lines up behind the first instead of
    # scheduling on top of it. Never earlier than the caller's `earliest`
    # (which carries the step's configured wait) or than now.
    def first_slot
      candidates = [@earliest, @now]
      tail = latest_scheduled
      candidates << (tail + interval) if tail
      candidates.max
    end

    def latest_scheduled
      CampaignEnrollment
        .where(sending_connection_key: @connection_key, status: %w[pending active])
        .maximum(:next_send_at)
    end
  end
end
