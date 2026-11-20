# frozen_string_literal: true

module Outreach
  # What a person has done with our messages, and what a good salesperson would
  # change because of it (backlog E105, Tom 2026-11-20: "learn from their
  # actions and adjust so it's more human like").
  #
  # - Watched the video or read their checkup: follow up sooner, stay on that
  #   topic, and lean toward the channel they acted on.
  # - Opened emails but never clicked: the topic is not landing, try another
  #   and keep it shorter.
  # - Two or more emails and no opens: the subject lines are not working.
  # - An email bounced: stop emailing them (Eligibility#emailable?).
  #
  # Only machine-checked clicks and opens count (LinkVisit, ScannerOpen), so a
  # link preview never makes us act as though they were interested.
  class Engagement
    # A rep who sees a click reaches out a little later, not the same minute.
    SOON = 2.hours
    # Never two messages closer together than this, whatever they did.
    MIN_GAP = 20.hours

    # Called when a person really clicks or reads their checkup. Brings the
    # next message forward, once per message sent.
    def self.interested!(target, at: Time.current)
      return unless OutreachTarget::WORKING.include?(target.status) && target.next_touch_at && target.last_sent_at

      earlier = target.outreach_events.where(event_type: %w[clicked report_viewed]).where('occurred_at >= ? AND occurred_at < ?', target.last_sent_at, at)
      return if earlier.exists?

      soon = [at + SOON, target.last_sent_at + MIN_GAP].max
      target.update!(next_touch_at: soon) if soon < target.next_touch_at
    end

    def initialize(target)
      @target = target
      @events = target.outreach_events.order(:occurred_at).to_a
    end

    def clicks
      @clicks ||= @events.select { |e| e.event_type == 'clicked' }
    end

    def watched_items
      ids = clicks.filter_map { |e| e.metadata['content_item_id'] }.uniq
      return [] if ids.empty?

      OutreachContentItem.where(id: ids, company_id: @target.company_id).to_a
    end

    def report_viewed?
      @events.any? { |e| e.event_type == 'report_viewed' }
    end

    def emails_sent
      @events.count { |e| e.event_type == 'sent' && e.channel == 'email' }
    end

    def emails_opened
      @events.select { |e| e.event_type == 'opened' }.map(&:communication_id).uniq.size
    end

    def engaged?
      clicks.any? || report_viewed?
    end

    # The channel they acted on most recently, or nil.
    def preferred_channel
      clicks.reverse.filter_map { |e| e.channel.presence }.first
    end

    # For the writer. Plain instructions, never numbers or times to repeat.
    def prompt_lines
      lines = []
      watched = watched_items
      if watched.any?
        titles = watched.map { |i| "\"#{i.title}\"" }.join(' and ')
        lines << "They watched #{titles}. That problem is the one that caught their eye, so stay on it: do NOT switch to a new problem. " \
                 'You may mention once, lightly, the way a person would ("since you had a look at the video"), then offer to show it live on ' \
                 'their own homes in the demo. Never say how you know, how many times, or when. Do not share that video again.'
      end
      if report_viewed?
        lines << 'They read their website checkup. You may say the demo can walk through what it found and what it means for buyers finding them. ' \
                 'Never quote the score or findings.'
      end
      if watched.empty? && !report_viewed?
        if emails_opened.positive?
          lines << 'They have opened your emails but not clicked anything (never mention this). The problems so far have not landed: pick a ' \
                   'clearly different one, and make this the shortest message yet.'
        elsif emails_sent >= 2
          lines << 'None of your emails has been opened (never mention this). If this is an email, the subject must be plainer and more ' \
                   'specific to them than before, like their town or a brand they sell.'
        end
      end
      lines.join("\n")
    end
  end
end
