# frozen_string_literal: true

module Outreach
  # The numbers for the results page (backlog E105). Daily rows count what
  # happened that day in the company's time zone; totals count people.
  class Results
    METRICS = %w[sent delivered opened clicked replied booked held no_show unsubscribed bounced undelivered handed_off].freeze
    DAYS = 45

    def initialize(wave)
      @wave = wave
      @zone = Clock.company_zone(wave.company)
    end

    def to_h
      { totals: totals, comparison: comparison, daily: daily, people: people, as_of: Time.current.iso8601, time_zone: @zone.name }
    end

    private

    def contact_events
      @wave.outreach_events.joins(:outreach_target).where(outreach_targets: { test_group: 'contact' })
    end

    def totals
      counts = contact_events.group(:event_type).distinct.count(:outreach_target_id)
      METRICS.index_with { |metric| counts[metric].to_i }.merge('messages_sent' => contact_events.where(event_type: 'sent').count)
    end

    def comparison
      %w[contact holdout].index_with do |group|
        scope = @wave.outreach_targets.where(test_group: group)
        events = @wave.outreach_events.where(outreach_target_id: scope.select(:id))
        { 'people' => scope.count, 'booked' => events.where(event_type: 'booked').distinct.count(:outreach_target_id),
          'held' => events.where(event_type: 'held').distinct.count(:outreach_target_id) }
      end
    end

    def daily
      rows = Hash.new { |hash, day| hash[day] = METRICS.index_with { 0 } }
      contact_events.where('occurred_at >= ?', DAYS.days.ago).pluck(:event_type, :occurred_at).each do |type, at|
        rows[at.in_time_zone(@zone).to_date.iso8601][type] += 1 if METRICS.include?(type)
      end
      rows.sort.reverse.map { |day, counts| { 'date' => day }.merge(counts) }
    end

    def people
      targets = @wave.contacted.includes(:lead).order(:rank).to_a
      latest = @wave.outreach_events.where(outreach_target_id: targets.map(&:id)).order(:occurred_at).group_by(&:outreach_target_id)
      targets.map do |target|
        last = latest[target.id]&.last
        { id: target.id, lead_id: target.lead_id, name: Assistant::Learn.display_name(target.lead), company: target.lead.company_name,
          status: target.status, stop_reason: target.stop_reason, touches: target.touch_count, last_event: last&.event_type,
          last_event_at: last&.occurred_at&.iso8601, next_touch_at: target.next_touch_at&.iso8601, conversation_id: target.conversation_id,
          booked_at: target.booked_at&.iso8601, held_at: target.held_at&.iso8601 }
      end
    end
  end
end
