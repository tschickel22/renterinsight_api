# frozen_string_literal: true

# Pulls page-level metrics (fans, engagement, reach, recent posts) from the
# Meta Graph API for the brand-health dashboard.
#
# Fails soft on insights / posts — if a token is missing a permission, we
# still return whatever we successfully retrieved rather than 500ing.
class BrandHealthService
  # Meta rejects the whole insights call if any single metric is unknown, so a
  # deprecated name silently zeroes the entire dashboard. `page_engaged_users`
  # and `page_views_total` were both removed in Meta's 2024 Page Insights
  # cull — page_post_engagements is the current stand-in for engagement.
  #
  # page_impressions_unique is reach: the number of people who saw the page,
  # counted once each. page_impressions counts every view. The dashboard used
  # to label impressions as "Reach", which reads as a much bigger audience than
  # the page has and disagrees with the same figure in Meta Business Suite.
  METRICS = %w[page_impressions_unique page_impressions page_post_engagements page_fans].freeze

  # Metric deprecation is continuous, so one bad name shouldn't cost us
  # everything. If the batch is rejected, step down rather than straight to the
  # floor: losing reach shouldn't also cost engagement and followers.
  METRIC_LADDER = [
    METRICS,
    %w[page_impressions page_post_engagements page_fans],
    %w[page_fans]
  ].freeze

  FALLBACK_METRICS = METRIC_LADDER.last

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

      insights_resp = fetch_insights(company, page_id, token)

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
        insights:     extract_insights(insights_resp).merge('posts_30d' => count_last_30_days(posts)),
        recent_posts: posts.map { |p| post_payload(p, owned) }
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

    def fetch_insights(company, page_id, token)
      last_error = nil

      METRIC_LADDER.each do |metrics|
        return request_insights(page_id, token, metrics)
      rescue MetaGraphApi::Error => e
        last_error = e
        Rails.logger.warn "[BrandHealthService] company=#{company.id} " \
                          "insights rejected for [#{metrics.join(',')}]: #{e.message}"
      end

      Rails.logger.warn "[BrandHealthService] company=#{company.id} insights skipped: #{last_error&.message}"
      { 'data' => [] }
    end

    def request_insights(page_id, token, metrics)
      MetaGraphApi.get("/#{page_id}/insights", token,
        metric: metrics.join(','),
        period: 'days_28')
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

    # Returns plain numbers keyed by metric name. This used to return
    # { latest:, total_28d: } per metric, which the dashboard read straight into
    # Number() — every tile rendered NaN and displayed as 0 no matter what Meta
    # actually returned.
    #
    # The most recent value is the answer, never the sum. We request
    # period=days_28, so each entry Meta returns is ALREADY the 28-day total
    # ending on its own end_time, and the response carries two or three such
    # windows. Adding them together counted most of the same 28 days two or
    # three times over, which is why the dashboard read far higher than the same
    # figures in Meta Business Suite. (Summing would be right for period=day.)
    def extract_insights(response)
      rows = Array(response['data'])
      METRICS.each_with_object({}) do |metric, out|
        row = rows.find { |r| r['name'] == metric }
        values = Array(row && row['values'])

        out[metric] = values.last.is_a?(Hash) ? numeric_value(values.last) : 0
      end
    end

    # A metric value is either a number or a breakdown hash keyed by segment.
    def numeric_value(entry)
      val = entry.is_a?(Hash) ? entry['value'] : entry
      case val
      when Numeric then val
      when Hash    then val.values.select { |x| x.is_a?(Numeric) }.sum
      else 0
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
