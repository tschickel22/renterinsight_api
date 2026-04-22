# frozen_string_literal: true

# Daily job. For each published SocialPost with an external_post_id, pulls
# reach/impressions/engagement/link_clicks from Meta and refreshes lead_count
# and deal_count from our own database (leads + converted accounts' deals).
class SyncSocialPostMetricsJob < ApplicationJob
  queue_as :low

  def perform
    synced = 0
    failed = 0

    SocialPost.where(status: 'published').where.not(external_post_id: nil).find_each do |post|
      begin
        refresh_from_meta(post)
        refresh_attribution_counts(post)
        post.update_column(:metrics_synced_at, Time.current)
        synced += 1
      rescue MetaGraphApi::ExpiredTokenError => e
        Rails.logger.warn "[SyncSocialPostMetricsJob] post=#{post.id} token expired: #{e.message}"
        failed += 1
      rescue MetaGraphApi::Error => e
        Rails.logger.error "[SyncSocialPostMetricsJob] post=#{post.id} API error: #{e.message}"
        failed += 1
      rescue => e
        Rails.logger.error "[SyncSocialPostMetricsJob] post=#{post.id} failed: #{e.class}: #{e.message}"
        failed += 1
      end
    end

    Rails.logger.info "[SyncSocialPostMetricsJob] synced=#{synced} failed=#{failed}"
  end

  private

  def refresh_from_meta(post)
    integration = access_integration_for(post)
    return unless integration

    basic = MetaGraphApi.get_post_basic_metrics(post.external_post_id, integration.page_access_token)

    likes    = basic.dig('likes', 'summary', 'total_count').to_i
    comments = basic.dig('comments', 'summary', 'total_count').to_i
    shares   = basic.dig('shares', 'count').to_i

    updates = {
      engagement_count: likes + comments + shares
    }

    # Insights (reach/impressions/clicks) may require additional permissions;
    # fail-soft so a permission error never breaks a whole sync run.
    begin
      insights = MetaGraphApi.get_post_insights(post.external_post_id, integration.page_access_token)
      data = Array(insights['data'])
      updates[:impressions] = insight_value(data, 'post_impressions')
      updates[:reach]       = insight_value(data, 'post_reach')
      updates[:link_clicks] = insight_value(data, 'post_clicks')
    rescue MetaGraphApi::Error => e
      Rails.logger.warn "[SyncSocialPostMetricsJob] post=#{post.id} insights skipped: #{e.message}"
    end

    post.update!(updates.compact)
  end

  def refresh_attribution_counts(post)
    lead_scope = Lead.where(company_id: post.company_id, social_post_id: post.id)
    lead_count = lead_scope.count

    converted_account_ids = lead_scope.where(is_converted: true).where.not(converted_account_id: nil).pluck(:converted_account_id).uniq
    deal_count = converted_account_ids.any? ? Deal.where(account_id: converted_account_ids).count : 0

    post.update_columns(lead_count: lead_count, deal_count: deal_count)
  end

  def access_integration_for(post)
    FacebookIntegration.active.where(company_id: post.company_id).order(:id).first
  end

  def insight_value(data, metric_key)
    row = data.find { |d| d['name'] == metric_key }
    return nil unless row
    values = Array(row['values'])
    values.last.is_a?(Hash) ? values.last['value'].to_i : nil
  end
end
