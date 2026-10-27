# frozen_string_literal: true

module Campaigns
  # Re-times everyone still waiting on a step after its wait or date is edited.
  #
  # An enrollment's next_send_at is fixed when it reaches a step, so changing a
  # step from "wait 3 days" to "send right away" used to leave everyone already
  # on it waiting the old 3 days (campaign 41, 2026-10-27).
  #
  # A wait change moves each send by the difference, which keeps the spacing
  # the pacer gave them. A date change times each send from the new date. Any
  # send that lands in the past is paced from now on its mailbox, as a fresh
  # enrollment would be, so a cohort does not all go out in the same second.
  class StepRescheduler
    def initialize(step, previous:, now: Time.current)
      @step = step
      @previous = previous # { wait_days:, wait_hours:, send_at: } before the edit
      @now = now
    end

    def call
      index = @step.campaign.campaign_steps.active.ordered.pluck(:id).index(@step.id)
      return 0 if index.nil?

      waiting = @step.campaign.campaign_enrollments
                     .where(status: %w[pending active], current_step_index: index)
                     .where.not(next_send_at: nil)
                     .where("COALESCE(campaign_enrollments.metadata->>'test_send', '') <> 'true'")
                     .order(:next_send_at, :id)

      pacers = Hash.new do |cache, key|
        cache[key] = Messaging::SendPacer.new(connection_key: key, earliest: @now, now: @now)
      end

      moved = 0
      waiting.find_each do |enrollment|
        due = new_due_for(enrollment, index)
        due = pacers[enrollment.sending_connection_key].next_slot if due <= @now
        next if due == enrollment.next_send_at

        enrollment.update_columns(next_send_at: due, updated_at: @now)
        moved += 1
      end
      moved
    end

    private

    def new_due_for(enrollment, index)
      if !@step.dated? && @previous[:send_at].blank?
        enrollment.next_send_at + (wait_seconds(@step.wait_days, @step.wait_hours) -
                                   wait_seconds(@previous[:wait_days], @previous[:wait_hours])).seconds
      else
        # Reached this step when the previous one went out, or on enrolling.
        arrived = index.zero? ? enrollment.created_at : (enrollment.last_sent_at || enrollment.created_at)
        @step.due_at(arrived)
      end
    end

    def wait_seconds(days, hours)
      (days.to_i * 86_400) + (hours.to_i * 3_600)
    end
  end
end
