# frozen_string_literal: true

# Dashboard endpoints for social attribution: how social posts are driving
# leads, pipeline, and deals across channels / posts / campaigns / reps.
class Api::V1::SocialAttributionController < ApplicationController
  before_action :set_company_scope

  BAND_ORDER = %w[hot warm lukewarm cold dead].freeze

  # GET /api/v1/social/attribution?from=...&to=...
  def index
    return unless authorize_action!('social_posts', 'read')

    from = parse_time(params[:from]) || 30.days.ago
    to   = parse_time(params[:to])   || Time.current

    leads = @company.leads
                    .where(created_at: from..to)
                    .where('utm_source IS NOT NULL OR social_post_id IS NOT NULL')

    total_social_leads = leads.count
    avg_health_score   = (leads.average(:health_score)&.to_f || 0.0).round(2)
    hot_leads          = leads.where('health_score >= ?', 80).count

    by_channel = group_with_score(leads.where.not(utm_medium: [nil, '']), :utm_medium)
    by_post    = group_with_score(leads.where.not(social_post_id: nil),   :social_post_id)
    by_campaign = group_with_score(leads.where.not(utm_campaign: [nil, '']), :utm_campaign)
    pipeline_health = BAND_ORDER.each_with_object({}) { |b, h| h[b] = 0 }.merge(band_counts(leads))

    # Decorate by_post with post headline/caption where available
    post_ids  = by_post.map { |row| row[:key] }.compact
    post_map  = @company.social_posts.where(id: post_ids).index_by(&:id)
    by_post.each do |row|
      p = post_map[row[:key].to_i]
      row[:headline]        = p&.headline
      row[:caption_preview] = p&.caption.to_s.truncate(120)
      row[:platform]        = p&.platform
      row[:intent_category] = p&.intent_category
    end

    render json: {
      range: { from: from.iso8601, to: to.iso8601 },
      totals: {
        total_social_leads: total_social_leads,
        avg_health_score:   avg_health_score,
        hot_leads:          hot_leads
      },
      by_channel:      by_channel,
      by_post:         by_post,
      by_campaign:     by_campaign,
      pipeline_health: pipeline_health
    }
  end

  # GET /api/v1/social/rep_leaderboard
  def rep_leaderboard
    return unless authorize_action!('social_posts', 'read')

    rep_posts = @company.social_posts.active.where(post_type: 'rep_personal')
                        .where.not(created_by_user_id: nil)

    posts_by_user = rep_posts.group(:created_by_user_id).count

    user_ids = posts_by_user.keys
    users    = User.where(id: user_ids, company_id: @company.id).index_by(&:id)

    rows = posts_by_user.map do |user_id, post_count|
      user = users[user_id]
      next unless user

      post_ids = rep_posts.where(created_by_user_id: user_id).pluck(:id)
      leads    = @company.leads.where(social_post_id: post_ids)

      lead_count      = leads.count
      avg_score       = (leads.average(:health_score)&.to_f || 0.0).round(2)
      converted_count = leads.where(is_converted: true).count

      {
        user_id:    user.id,
        name:       "#{user.first_name} #{user.last_name}".strip.presence || user.email,
        email:      user.email,
        post_count: post_count,
        lead_count: lead_count,
        avg_health_score: avg_score,
        deal_count: converted_count
      }
    end.compact

    rows.sort_by! { |r| [-r[:lead_count], -r[:avg_health_score], -r[:post_count]] }

    render json: rows
  end

  # GET /api/v1/social/advisor
  def advisor
    return unless authorize_action!('social_posts', 'read')

    cutoff = 60.days.ago
    posts = @company.social_posts.active.where(status: 'published')
                   .where('published_at >= ?', cutoff)

    recommendations = posts.map do |post|
      leads      = @company.leads.where(social_post_id: post.id)
      lead_count = leads.count
      avg_score  = (leads.average(:health_score)&.to_f || 0.0).round(2)
      age_days   = ((Time.current - post.published_at) / 1.day).to_i

      action, reason, tips = classify(lead_count: lead_count, avg_score: avg_score, age_days: age_days, post: post)

      {
        post_id:          post.id,
        headline:         post.headline,
        caption_preview:  post.caption.to_s.truncate(120),
        platform:         post.platform,
        intent_category:  post.intent_category,
        published_at:     post.published_at,
        age_days:         age_days,
        lead_count:       lead_count,
        avg_health_score: avg_score,
        action:           action,
        reason:           reason,
        tips:             tips
      }
    end

    order = { 'scale' => 0, 'edit' => 1, 'wait' => 2, 'cut' => 3 }
    recommendations.sort_by! { |r| [order[r[:action]] || 99, -r[:lead_count], -r[:avg_health_score]] }

    render json: recommendations
  end

  private

  def parse_time(value)
    return nil if value.blank?
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def group_with_score(scope, column)
    counts = scope.group(column).count
    avgs   = scope.group(column).average(:health_score)

    counts.map do |key, count|
      {
        key:              key,
        lead_count:       count,
        avg_health_score: (avgs[key]&.to_f || 0.0).round(2)
      }
    end.sort_by { |row| -row[:lead_count] }
  end

  def band_counts(scope)
    counts = Hash.new(0)
    scope.find_each(batch_size: 500) do |lead|
      counts[band_for(lead.health_score.to_i)] += 1
    end
    counts
  end

  def band_for(score)
    return 'dead' if score < 0
    return 'hot'      if score >= 80
    return 'warm'     if score >= 50
    return 'lukewarm' if score >= 25
    'cold'
  end

  def classify(lead_count:, avg_score:, age_days:, post:)
    if age_days < 7 && lead_count < 5
      return ['wait', "Too early to judge — only #{age_days}d old with #{lead_count} leads.",
              ['Let it run another week before acting.',
               'Watch the health score trend once 10+ leads land.']]
    end

    if avg_score >= 65 && lead_count >= 5
      return ['scale', "Strong performer: #{lead_count} leads, avg score #{avg_score}.",
              ['Duplicate this post with variant copy.',
               'Increase ad spend / boost for 7 more days.',
               'Create a similar post for adjacent inventory.']]
    end

    if lead_count.zero? && age_days >= 14
      return ['cut', "No leads in #{age_days}d — the creative isn\'t landing.",
              ['Archive; stop spend if boosted.',
               'Replace with a different intent_category (e.g., specific_unit or social_proof).']]
    end

    if avg_score < 15 && lead_count >= 5
      return ['cut', "#{lead_count} leads at avg score #{avg_score} — volume without quality.",
              ['Audience targeting is off — tighten geo or interests.',
               'Revisit CTA; likely attracting tire-kickers.']]
    end

    tips = []
    tips << 'Try a stronger first-line hook (question or price).'
    tips << 'Add or refresh the primary image.'         if post.image_urls.blank?
    tips << 'Add a clearer CTA (shop_now or message_us).' if post.cta_type.blank?
    tips << 'Consider a rep_personal variant for authenticity.' if post.post_type != 'rep_personal'
    ['edit', "Mid performance: #{lead_count} leads, avg score #{avg_score}.", tips]
  end
end
