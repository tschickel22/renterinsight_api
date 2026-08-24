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
    # How far ahead a committed send still counts against the mailbox's near-term
    # capacity. A send scheduled next week does not make a send today unsafe.
    PACING_HORIZON = 24.hours

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

    # Start far enough out that this batch does not exceed the mailbox rate when
    # added to what is already committed. Never earlier than the caller's
    # `earliest` (which carries the step's configured wait) or than now.
    #
    # This used to chase the MAXIMUM next_send_at on the mailbox and start one
    # interval past it. That conflates two different things a next_send_at can
    # mean. For a batch being paced it is a slot claim, and lining up behind the
    # last one is right. For an enrollment sitting mid-drip it is a configured
    # WAIT, and a five-day step-4 wait is not five days of queue depth: it is one
    # message, five days out. Campaign 31 launched behind campaign 26's drip tail
    # and had its zero-wait first step scheduled four days late, with the delay
    # ratcheting further out for each campaign launched after it.
    #
    # Counting committed sends instead prices each one at what it actually costs
    # the mailbox, one interval, wherever it happens to sit. A drip step days out
    # contributes its interval and nothing more.
    def first_slot
      committed = committed_ahead
      candidates = [@earliest, @now]
      candidates << (@now + (committed * interval).seconds) if committed.positive?
      candidates.max
    end

    # Sends already committed on this mailbox inside the pacing horizon. Anything
    # beyond it is not competing for near-term capacity and is deliberately not
    # counted — that is the whole point of the change above.
    def committed_ahead
      CampaignEnrollment
        .where(sending_connection_key: @connection_key, status: %w[pending active])
        .where(next_send_at: @now..(@now + PACING_HORIZON))
        .count
    end
  end
end
