# frozen_string_literal: true

# Pulls page-level metrics (followers, views, engagement, recent posts) from
# the Meta Graph API for the brand-health dashboard.
#
# Fails soft on insights / posts: if a token is missing a permission, we still
# return whatever we successfully retrieved rather than 500ing. A metric that
# failed comes back as nil, never 0, so the dashboard can say "Unavailable"
# instead of reporting an empty page.
class BrandHealthService
  # Verified against our own Page on Graph v25.0, 2026-09-18. Meta retired the
  # impressions family (2025-11-15) and the page_fans family (2026-06-15):
  # page_impressions, page_impressions_unique, page_fans, page_fan_adds and
  # page_engaged_users are all gone. There is no reach metric left at all, so
  # "Views" (page_views_total) is the closest thing, and is what the Facebook
  # app and Meta Business Suite now show.
  #
  # Meta rejects a whole multi-metric call with "(#100) The value must be a
  # valid insights metric" if ANY one name is retired. Batching them is what
  # zeroed Engagement too, even though page_post_engagements still works. So
  # each metric is its own request: the next retirement costs one tile, and
  # the log line names it.
  METRICS = %w[page_views_total page_post_engagements page_follows page_video_views].freeze

  # The dashboard tiles are 28-day totals. period=day on a small Page is
  # legitimately 0 most days, and adding daily buckets is the wrong shape
  # anyway; days_28 returns the rolling total directly.
  PERIOD = 'days_28'

  class << self
    def fetch_for_company(company)
      integration = FacebookIntegration.current_for(company)
      return nil unless integration

      token   = integration.page_access_token
      page_id = integration.page_id

      page_data = begin
        MetaGraphApi.get("/#{page_id}", token,
          fields: 'id,name,fan_count,followers_count,talking_about_count,link,picture')
      rescue MetaGraphApi::Error => e
        Rails.logger.warn "[BrandHealthService] company=#{company.id} page data failed: #{e.message}"
        return nil
      end

      # Temporary, see MetaAppReview: without read_insights the call can only
      # fail, and zeros would read as a page nobody sees.
      insights_ok = MetaAppReview.insights?(company)
      insights    = insights_ok ? fetch_insights(company, page_id, token) : {}

      # 25 rather than 10 so the 30-day count below is right for an active page;
      # the dashboard still only renders the first handful.
      posts_resp = begin
        MetaGraphApi.get("/#{page_id}/posts", token,
          fields: 'id,message,created_time,permalink_url,full_picture,likes.summary(true),comments.summary(true),shares',
          limit:  25)
      rescue MetaGraphApi::Error => e
        Rails.logger.warn "[BrandHealthService] company=#{company.id} posts skipped: #{e.message}"
        { 'data' => [] }
      end

      posts = Array(posts_resp['data'])
      owned = owned_post_ids(company, posts)

      {
        page:         page_payload(page_data),
        insights:     insights.merge('posts_30d' => count_last_30_days(posts)),
        recent_posts: posts.map { |p| post_payload(p, owned) },
        capabilities: MetaAppReview.capabilities(company)
      }
    end

    private

    # Maps a Facebook post id back to the SocialPost we published it from, so a
    # card can offer to open its comments here instead of sending the user to
    # Facebook to moderate. A post made directly on the Page has no row and is
    # deliberately absent: we hold no comments for it to show.
    #
    # One query for the whole strip rather than a lookup per card.
    def owned_post_ids(company, posts)
      ids = posts.filter_map { |p| p['id'].presence }
      return {} if ids.empty?

      company.social_posts
             .where(external_post_id: ids)
             .pluck(:external_post_id, :id)
             .to_h
    end

    # One request per metric, so a retired name cannot take the others with it.
    # Returns { metric => number or nil }; nil means we could not get it.
    def fetch_insights(company, page_id, token)
      METRICS.each_with_object({}) do |metric, out|
        out[metric] = fetch_metric(company, page_id, token, metric)
      end
    end

    def fetch_metric(company, page_id, token, metric)
      response = MetaGraphApi.get("/#{page_id}/insights", token, metric: metric, period: PERIOD)
      row = Array(response['data']).find { |r| r['name'] == metric }
      values = Array(row && row['values'])

      unless values.last.is_a?(Hash)
        Rails.logger.warn "[BrandHealthService] company=#{company.id} metric=#{metric} returned no values"
        return nil
      end

      # The most recent value is the answer, never the sum. With days_28 each
      # entry is ALREADY the 28-day total ending on its own end_time, and Meta
      # returns two or three such windows. Adding them counted most of the same
      # 28 days two or three times over.
      numeric_value(values.last)
    rescue MetaGraphApi::Error => e
      # Graph's full response body is already logged by MetaGraphApi; this line
      # ties it to the metric, so a retirement is obvious from the logs.
      Rails.logger.error "[BrandHealthService] company=#{company.id} metric=#{metric} period=#{PERIOD} " \
                         "unavailable: code=#{e.code.inspect} subcode=#{e.subcode.inspect} " \
                         "fbtrace_id=#{e.fbtrace_id.inspect} message=#{e.message}"
      nil
    end

    def page_payload(page_data)
      {
        id:            page_data['id'],
        name:          page_data['name'],
        followers:     page_data['followers_count'] || page_data['fan_count'] || 0,
        talking_about: page_data['talking_about_count'] || 0,
        picture_url:   page_data.dig('picture', 'data', 'url'),
        link:          page_data['link']
      }
    end

    # A metric value is either a number or a breakdown hash keyed by segment.
    # Anything else is unreadable, which is not the same as zero.
    def numeric_value(entry)
      val = entry.is_a?(Hash) ? entry['value'] : entry
      case val
      when Numeric then val
      when Hash    then val.values.select { |x| x.is_a?(Numeric) }.sum
      end
    end

    # Fallback for a post Graph returns without a permalink. A page post id is
    # "{page_id}_{post_id}", which facebook.com resolves directly — the same
    # shape SocialCommentMailer already links to.
    def facebook_post_url(post_id)
      return nil if post_id.blank?

      "https://www.facebook.com/#{post_id}"
    end

    def count_last_30_days(posts)
      cutoff = 30.days.ago
      posts.count do |p|
        created = p['created_time']
        next false if created.blank?

        # Time.zone.parse returns nil for unparseable input rather than raising,
        # so nil has to be handled as well as the exception.
        parsed = begin
          Time.zone.parse(created.to_s)
        rescue ArgumentError, TypeError
          nil
        end

        parsed.present? && parsed >= cutoff
      end
    end

    def post_payload(p, owned = {})
      {
        id:           p['id'],
        # Present only for a post we published, which is the only kind whose
        # comments we sync. Drives the card's link into the Comments tab.
        social_post_id: owned[p['id']],
        message:      p['message']&.truncate(150),
        created_time: p['created_time'],
        # Where the card's View link points. Without it the frontend fell back
        # to href="#", so every card on the Page strip just jumped to the top of
        # the dashboard instead of opening the post.
        link:         p['permalink_url'].presence || facebook_post_url(p['id']),
        image_url:    p['full_picture'],
        likes:        p.dig('likes', 'summary', 'total_count') || 0,
        # Whether the Page itself has already liked this, so the button knows
        # which way it toggles. Comes back on the read, there is no endpoint
        # that answers it separately.
        has_liked:    p.dig('likes', 'summary', 'has_liked') || false,
        comments:     p.dig('comments', 'summary', 'total_count') || 0,
        shares:       p.dig('shares', 'count') || 0
      }
    end
  end
end
