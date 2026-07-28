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
  METRICS = %w[page_impressions page_post_engagements page_fans].freeze

  # Metric deprecation is continuous, so one bad name shouldn't cost us
  # everything. If the batch is rejected, retry with the least likely to move.
  FALLBACK_METRICS = %w[page_fans].freeze

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

      posts_resp = begin
        MetaGraphApi.get("/#{page_id}/posts", token,
          fields: 'id,message,created_time,full_picture,likes.summary(true),comments.summary(true),shares',
          limit:  10)
      rescue MetaGraphApi::Error => e
        Rails.logger.warn "[BrandHealthService] company=#{company.id} posts skipped: #{e.message}"
        { 'data' => [] }
      end

      {
        page:         page_payload(page_data),
        insights:     extract_insights(insights_resp),
        recent_posts: Array(posts_resp['data']).map { |p| post_payload(p) }
      }
    end

    private

    def fetch_insights(company, page_id, token)
      request_insights(page_id, token, METRICS)
    rescue MetaGraphApi::Error => e
      Rails.logger.warn "[BrandHealthService] company=#{company.id} insights retry after: #{e.message}"
      begin
        request_insights(page_id, token, FALLBACK_METRICS)
      rescue MetaGraphApi::Error => retry_error
        Rails.logger.warn "[BrandHealthService] company=#{company.id} insights skipped: #{retry_error.message}"
        { 'data' => [] }
      end
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

    def extract_insights(response)
      rows = Array(response['data'])
      METRICS.each_with_object({}) do |metric, out|
        row = rows.find { |r| r['name'] == metric }
        values = Array(row && row['values'])
        latest = values.last.is_a?(Hash) ? values.last['value'] : nil

        total = values.sum do |v|
          case (val = v.is_a?(Hash) ? v['value'] : nil)
          when Numeric then val
          when Hash    then val.values.select { |x| x.is_a?(Numeric) }.sum
          else 0
          end
        end

        out[metric] = { latest: latest, total_28d: total }
      end
    end

    def post_payload(p)
      {
        id:           p['id'],
        message:      p['message']&.truncate(150),
        created_time: p['created_time'],
        image_url:    p['full_picture'],
        likes:        p.dig('likes', 'summary', 'total_count') || 0,
        comments:     p.dig('comments', 'summary', 'total_count') || 0,
        shares:       p.dig('shares', 'count') || 0
      }
    end
  end
end
