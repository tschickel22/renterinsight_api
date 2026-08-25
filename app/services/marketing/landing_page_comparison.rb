# frozen_string_literal: true

module Marketing
  # Every landing page's headline numbers in one table.
  #
  # The per-page report answers "how is this page doing". It cannot answer "which
  # of these is doing better", which is the question someone running two ads
  # against two pages actually has, and answering it meant opening each page in
  # turn and holding the numbers in your head.
  #
  # Definitions are deliberately the same ones LandingPageAnalytics uses, down to
  # the rounding. A summary that disagrees with the page it summarises is worse
  # than no summary: whichever number the reader saw second is the one they stop
  # trusting.
  #
  # Grouped queries rather than the per-page service in a loop. That service runs
  # a dozen queries per page, so a dealer with twenty pages would pay for two
  # hundred and forty to draw one table.
  class LandingPageComparison
    DEFAULT_WINDOW_DAYS = 30

    def initialize(pages, from: nil, to: nil)
      @pages = Array(pages)
      @to = to || Time.current
      @from = from || DEFAULT_WINDOW_DAYS.days.ago
    end

    def call
      {
        items: @pages.map { |page| row_for(page) },
        window: { from: @from, to: @to }
      }
    end

    private

    def page_ids
      @page_ids ||= @pages.map(&:id)
    end

    # Bots excluded here exactly as they are in the per-page report. A crawler
    # that runs JavaScript inflates every number, and the comparison is the view
    # most likely to be skimmed rather than read.
    def visits
      @visits ||= PageVisit.real
                           .where(website_page_id: page_ids)
                           .where(first_seen_at: @from..@to)
    end

    def counts_by_page
      @counts_by_page ||= visits.group(:website_page_id).count
    end

    def unique_by_page
      @unique_by_page ||= visits.group(:website_page_id).distinct.count(:visitor_token)
    end

    def conversions_by_page
      @conversions_by_page ||= visits.converted.group(:website_page_id).count
    end

    def identified_by_page
      @identified_by_page ||= visits.identified.group(:website_page_id).count
    end

    # One query for every event type the table shows, rather than one per type
    # per page.
    def event_counts
      @event_counts ||= PageVisitEvent
                        .joins(:page_visit)
                        .where(page_visits: { id: visits.select(:id) })
                        .where(event_type: %w[form_start cta_click video_play])
                        .group('page_visits.website_page_id', :event_type)
                        .distinct
                        .count('page_visits.id')
    end

    def scroll_by_page
      @scroll_by_page ||= visits.group(:website_page_id).average(:max_scroll_depth)
    end

    def row_for(page)
      total = counts_by_page[page.id].to_i
      submits = conversions_by_page[page.id].to_i
      starts = event_counts[[page.id, 'form_start']].to_i

      {
        id: page.id,
        title: page.title,
        path: page.path,
        published: page.published?,
        visits: total,
        unique_visitors: unique_by_page[page.id].to_i,
        identified: identified_by_page[page.id].to_i,
        form_starts: starts,
        conversions: submits,
        conversion_rate: percentage(submits, total),
        form_completion_rate: percentage(submits, starts),
        cta_clicks: event_counts[[page.id, 'cta_click']].to_i,
        video_plays: event_counts[[page.id, 'video_play']].to_i,
        avg_scroll_depth: scroll_by_page[page.id]&.to_f&.round(1) || 0.0
      }
    end

    def percentage(numerator, denominator)
      return 0.0 if denominator.to_i.zero?

      ((numerator.to_f / denominator) * 100).round(1)
    end
  end
end
