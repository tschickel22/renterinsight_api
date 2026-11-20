# frozen_string_literal: true

module Outreach
  # What a running wave does on each tick (backlog E105): bring results up to
  # date, pause if something looks wrong, then send what is due.
  class WaveRunner
    MAX_PER_TICK = 10
    RESULTS_FOR = 120.days

    def self.run_all
      OutreachWave.where(status: 'running').find_each do |wave|
        new(wave).run
      rescue StandardError => e
        Rails.logger.error("[Outreach::WaveRunner] wave #{wave.id}: #{e.class}: #{e.message}")
      end
      # Stopped waves send nothing, but their demos still count in the results.
      OutreachWave.where(status: %w[paused completed]).where('started_at >= ?', RESULTS_FOR.ago).find_each do |wave|
        Sync.new(wave).run
      rescue StandardError => e
        Rails.logger.error("[Outreach::WaveRunner] sync of wave #{wave.id}: #{e.class}: #{e.message}")
      end
    end

    def initialize(wave)
      @wave = wave
      @company = wave.company
      @settings = Settings.for(@company)
      @eligibility = Eligibility.new(@company)
    end

    def run
      Sync.new(@wave).run
      return pause!('Proactive Outreach was turned off') unless @settings.active?

      problem = Safety.new(@wave).problem
      return pause!(problem) if problem

      send_openers
      send_follow_ups
      finish_if_done
    end

    private

    def pause!(reason)
      @wave.update!(status: 'paused', pause_reason: reason, paused_at: Time.current)
      person = @settings.sender
      return unless person

      NotificationService.create(
        recipient: person, notification_type: :assistant_handoff, company_id: @company.id,
        message: "Proactive Outreach paused \"#{@wave.name}\": #{reason}", action_text: 'Open results',
        action_url: '/settings?tab=customize&section=outreach', deliver_now: true
      )
    rescue StandardError => e
      Rails.logger.error("[Outreach::WaveRunner] pause notice failed: #{e.message}")
    end

    def sent_today
      zone = Clock.company_zone(@company)
      @wave.contacted.where('first_sent_at >= ?', Time.current.in_time_zone(zone).beginning_of_day).count
    end

    def send_openers
      room = [@wave.daily_limit - sent_today, MAX_PER_TICK].min
      return unless room.positive?

      @wave.contacted.where(status: 'approved').includes(:lead).order(:rank).each do |target|
        break if room <= 0
        next unless Clock.send_now?(target.lead, @company)

        room -= 1 if send_opener(target)
      end
    end

    def send_opener(target)
      reason = @eligibility.blocked_reason(target.lead, override: target.override_reason.present?)
      if reason
        target.record!('skipped', metadata: { reason: reason })
        target.stop!(reason)
        return false
      end
      unless @wave.allows?(target.channel) && @wave.opening_channel(@eligibility.reach(target.lead))
        target.record!('skipped', metadata: { reason: "cannot be reached by #{@wave.channels_label.downcase}" })
        target.stop!("cannot be reached by #{@wave.channels_label.downcase}")
        return false
      end
      return false unless claim(target, 'approved')

      Sender.new(target).deliver!(body: target.draft_body, subject: target.draft_subject, channel: target.channel, kind: 'opener',
                                  content_item: @company.outreach_content_items.approved.find_by(id: target.draft_content_item_id))
      true
    rescue StandardError => e
      Rails.logger.error("[Outreach::WaveRunner] opener for target #{target.id}: #{e.class}: #{e.message}")
      target.stop!("could not send: #{e.message.truncate(120)}")
      false
    end

    # Only one worker may send to a person.
    def claim(target, from)
      target.with_lock do
        next false unless target.status == from

        target.update!(status: 'sending')
        true
      end
    end

    def send_follow_ups
      due = @wave.contacted.where(status: OutreachTarget::WORKING).where('next_touch_at <= ?', Time.current).includes(:lead).limit(MAX_PER_TICK)
      due.each do |target|
        next unless Clock.send_now?(target.lead, @company)

        send_follow_up(target)
      rescue StandardError => e
        Rails.logger.error("[Outreach::WaveRunner] follow-up for target #{target.id}: #{e.class}: #{e.message}")
        target.update!(next_touch_at: 1.day.from_now)
      end
    end

    def send_follow_up(target)
      return target.update!(next_touch_at: nil) unless target.conversation&.assistant_answering?

      reason = @eligibility.stop_reason(target.lead, override: target.override_reason.present?)
      return target.stop!(reason) if reason

      channel = @wave.next_channel(@eligibility.reach(target.lead), last: target.last_channel)
      return target.stop!("cannot be reached by #{@wave.channels_label.downcase}") unless channel

      plan = Sender::GAPS.size + 1
      result = Writer.new(target).follow_up(channel, number: target.touch_count, of: plan - 1, booking: Booking.new(target.conversation))
      return target.update!(next_touch_at: 1.day.from_now) if result.problem

      Sender.new(target).deliver!(body: result.body, subject: result.subject, channel: channel, kind: 'follow_up', content_item: result.content_item,
                                  report: result.share_report)
    end

    def finish_if_done
      return if @wave.contacted.where(status: %w[approved sending]).exists?
      return if @wave.contacted.where(status: OutreachTarget::WORKING).where.not(next_touch_at: nil).exists?

      @wave.update!(status: 'completed', completed_at: Time.current)
    end
  end
end
