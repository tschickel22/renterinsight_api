# frozen_string_literal: true

module Marketing
  # Reads a landing page's performance out of page_visits / page_visit_events.
  #
  # Everything here excludes bots. A crawler that executes JavaScript inflates
  # every number, and a dealer who sees 400 "visits" and no enquiries loses
  # faith in the whole feature on day one.
  class LandingPageAnalytics
    DEFAULT_WINDOW_DAYS = 30

    def initialize(page, from: nil, to: nil)
      @page = page
      @to = to || Time.current
      @from = from || DEFAULT_WINDOW_DAYS.days.ago
    end

    def call
      {
        funnel: funnel,
        engagement: engagement,
        video: video,
        sources: sources,
        timeseries: timeseries,
        window: { from: @from, to: @to }
      }
    end

    private

    def visits
      @visits ||= PageVisit.real
                           .where(website_page_id: @page.id)
                           .where(first_seen_at: @from..@to)
    end

    def visit_ids
      @visit_ids ||= visits.pluck(:id)
    end

    def events
      @events ||= PageVisitEvent.where(page_visit_id: visit_ids)
    end

    # The steps that actually matter on a landing page, in order. Unique
    # visitors rather than visits, because one person returning three times is
    # one person deciding.
    def funnel
      total = visits.count
      unique = visits.distinct.count(:visitor_token)
      starts = events.of_type('form_start').distinct.count(:page_visit_id)
      submits = visits.converted.count

      {
        visits: total,
        unique_visitors: unique,
        identified: visits.identified.count,
        form_starts: starts,
        conversions: submits,
        # Of those who started the form, how many finished. A page with many
        # starts and few submits has a form problem, not a traffic problem.
        form_completion_rate: percentage(submits, starts),
        conversion_rate: percentage(submits, total)
      }
    end

    def engagement
      depths = visits.pluck(:max_scroll_depth)
      durations = visits.where('duration_ms > 0').pluck(:duration_ms)

      {
        avg_scroll_depth: depths.any? ? (depths.sum.to_f / depths.size).round(1) : 0,
        reached_bottom: visits.where('max_scroll_depth >= 100').count,
        # A visit with no scroll and no event is someone who saw the hero and
        # left. Counted explicitly because it is the number a headline should
        # be judged on.
        bounced: visits.where(max_scroll_depth: 0, converted: false).count,
        median_duration_ms: median(durations),
        cta_clicks: events.of_type('cta_click').count,
        outbound_clicks: events.of_type('outbound_click').count
      }
    end

    # Quartiles are what make a video block justifiable: a page where most
    # visitors reach 75% is working even before anyone submits.
    # Video engagement.
    #
    # `plays` means two different things depending on how the video is set up,
    # and reporting one number for both invites a wrong reading. A click-to-play
    # video counts people who chose to watch. An autoplaying one counts everyone
    # the page loaded for, so plays equals visits and a completion rate measured
    # against it is really "how far into the clip the average visitor stayed".
    # auto_started says which it is, taken from the events themselves rather
    # than from the block's current setting, so a page whose author changed the
    # setting last week does not have its old numbers relabelled.
    def video
      plays = events.of_type('video_play').distinct.count(:page_visit_id)
      return { plays: 0 } if plays.zero?

      completed = events.of_type('video_complete').distinct.count(:page_visit_id)

      {
        plays: plays,
        auto_started: auto_started_plays.positive?,
        quartile_25: events.of_type('video_25').distinct.count(:page_visit_id),
        quartile_50: events.of_type('video_50').distinct.count(:page_visit_id),
        quartile_75: events.of_type('video_75').distinct.count(:page_visit_id),
        completed: completed,
        completion_rate: percentage(completed, plays),
        # Someone reaching for the speaker on a muted autoplaying clip is asking
        # to hear it. On a video with no narration that is the answer to whether
        # recording some is worth it.
        unmuted: events.of_type('video_unmute').distinct.count(:page_visit_id),
        unmute_rate: percentage(events.of_type('video_unmute').distinct.count(:page_visit_id), plays)
      }
    end

    def auto_started_plays
      events.of_type('video_play').where("payload ->> 'autoplay' = 'true'").count
    rescue StandardError
      # payload shape is the client's, and a reporting nicety must not take the
      # whole analytics response down with it.
      0
    end

    def sources
      {
        by_utm_source: visits.group(:utm_source).count.transform_keys { |k| k.presence || 'direct' },
        by_campaign: visits.where.not(campaign_id: nil).group(:campaign_id).count,
        by_device: visits.group(:device_type).count.transform_keys { |k| k.presence || 'unknown' }
      }
    end

    def timeseries
      visits.group("DATE(page_visits.first_seen_at)").count.map do |date, count|
        conversions = visits.converted.where('DATE(page_visits.first_seen_at) = ?', date).count
        { date: date.to_s, visits: count, conversions: conversions }
      end.sort_by { |row| row[:date] }
    end

    def percentage(numerator, denominator)
      return 0.0 if denominator.to_i.zero?

      ((numerator.to_f / denominator) * 100).round(1)
    end

    # Median, not mean: one visitor who left a tab open for four hours would
    # otherwise report an average that describes nobody.
    def median(values)
      return 0 if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2)
    end
  end
end
