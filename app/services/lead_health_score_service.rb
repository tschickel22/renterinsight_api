# frozen_string_literal: true

# Calculates a "health" score for a Lead (0-100, capped), with breakdown and band.
#
# Score = origin + engagement + fit - decay
#
# Bands:
#   80+     → hot
#   50-79   → warm
#   25-49   → lukewarm
#   0-24    → cold
#   < 0     → dead (persisted as the capped value with band 'dead')
class LeadHealthScoreService
  ORIGIN_SCORES = {
    'specific_unit' => 20,
    'price_drop'    => 18,
    'financing'     => 15,
    'paid_ad'       => 15,
    'social_proof'  => 12,
    'lifestyle'     => 10,
    'education'     => 8,
    'seasonal'      => 10,
    'rep_post'      => 8
  }.freeze

  ACTIVITY_SCORES = {
    'call'                   => 20,
    'visit'                  => 40,
    'meeting'                => 30,
    'deal_created'           => 50,
    'email_reply'            => 15,
    'sms_reply'              => 15,
    'note'                   => 5,
    'task'                   => 5,
    'reminder'               => 2,
    'campaign_email_opened'  => 3,
    'campaign_link_clicked'  => 20,
    'campaign_replied'       => 25,
    'quote_viewed'           => 30,
    'email_opened'           => 2
  }.freeze

  ENGAGEMENT_CAP    = 60
  HOT_REOPENER_BONUS = 15

  FIT_SCORES = {
    'timeline_asap'       => 25,
    'timeline_3_months'   => 15,
    'timeline_6_months'   => 8,
    'has_land'            => 30,
    'financing_prequal'   => 20,
    'budget_qualified'    => 15
  }.freeze

  BANDS = [
    [80, 'hot'],
    [50, 'warm'],
    [25, 'lukewarm'],
    [0,  'cold']
  ].freeze

  SCORE_CAP = 100

  attr_reader :lead

  def initialize(lead)
    @lead = lead
  end

  # Returns a hash: { score:, band:, breakdown: }
  def calculate
    origin     = origin_score
    engagement = engagement_score
    fit        = fit_score
    decay      = decay_penalty

    total  = origin[:total] + engagement[:total] + fit[:total] - decay[:total]
    capped = [total, SCORE_CAP].min

    {
      score: capped,
      band:  band_for(capped),
      breakdown: {
        origin:     origin,
        engagement: engagement,
        fit:        fit,
        decay:      decay,
        raw_total:  total,
        capped_at:  SCORE_CAP
      }
    }
  end

  # Persist score to lead + create a lead_scores history row.
  def save!
    result = calculate

    Lead.transaction do
      lead.update_columns(
        health_score:             result[:score],
        health_score_updated_at:  Time.current,
        last_activity_scored_at:  Time.current
      )

      LeadScore.create!(
        lead_id:   lead.id,
        score:     result[:score],
        reason:    "recalculated: #{result[:band]}",
        band:      result[:band],
        breakdown: result[:breakdown]
      )
    end

    result
  end

  private

  def origin_score
    intent = lead.social_intent.to_s
    points = ORIGIN_SCORES[intent] || 0
    { total: points, intent: intent, value: points }
  end

  def engagement_score
    return { total: 0, activities: {} } unless lead.respond_to?(:lead_activities)

    counts = lead.lead_activities.group(:activity_type).count
    breakdown = {}
    total = 0

    counts.each do |type, count|
      points = (ACTIVITY_SCORES[type.to_s] || 0) * count
      next if points.zero?
      breakdown[type] = { count: count, points: points }
      total += points
    end

    # Optional bonus for visit/deal from activities marked with outcome
    if lead.respond_to?(:activities)
      visits = lead.activities.where(activity_type: 'visit').count rescue 0
      if visits.positive?
        breakdown['visit'] = { count: visits, points: ACTIVITY_SCORES['visit'] * visits }
        total += ACTIVITY_SCORES['visit'] * visits
      end
    end

    if lead.respond_to?(:converted?) && lead.converted?
      breakdown['deal_created'] = { points: ACTIVITY_SCORES['deal_created'] }
      total += ACTIVITY_SCORES['deal_created']
    end

    # Campaign engagement signals
    campaign_enrollments = CampaignEnrollment.where(recipient_type: 'Lead', recipient_id: lead.id)
    if campaign_enrollments.any?
      sends = CampaignSend.where(campaign_enrollment_id: campaign_enrollments.select(:id))

      # Opens — recency-weighted (today full, older 50%)
      recent_opens = sends.where('opened_at >= ?', 7.days.ago)
      opens_today  = recent_opens.where('opened_at >= ?', 24.hours.ago).sum(:open_count)
      opens_week   = recent_opens.where('opened_at < ?', 24.hours.ago).sum(:open_count)

      open_points = (opens_today * ACTIVITY_SCORES['campaign_email_opened']) +
                    (opens_week  * ACTIVITY_SCORES['campaign_email_opened'] * 0.5).to_i

      if open_points.positive?
        breakdown['campaign_email_opened'] = { count: opens_today + opens_week, points: open_points }
        total += open_points
      end

      # Clicks — full weight, strong intent signal
      click_count  = sends.where('clicked_at >= ?', 7.days.ago).sum(:click_count)
      click_points = click_count * ACTIVITY_SCORES['campaign_link_clicked']

      if click_points.positive?
        breakdown['campaign_link_clicked'] = { count: click_count, points: click_points }
        total += click_points
      end

      # Replies
      reply_count  = sends.where('replied_at >= ?', 30.days.ago).count
      reply_points = reply_count * ACTIVITY_SCORES['campaign_replied']
      if reply_points.positive?
        breakdown['campaign_replied'] = { count: reply_count, points: reply_points }
        total += reply_points
      end

      # Hot reopener bonus — single send opened 3+ times in last 48h
      hot_reopener = sends.where('open_count >= ? AND opened_at >= ?', 3, 48.hours.ago).exists?
      if hot_reopener
        breakdown['hot_reopener_bonus'] = { points: HOT_REOPENER_BONUS }
        total += HOT_REOPENER_BONUS
      end
    end

    # Non-campaign email opens (CommunicationEvent)
    direct_opens = CommunicationEvent.joins(:communication)
                                     .where(communications: { communicable_type: 'Lead', communicable_id: lead.id })
                                     .where(event_type: 'opened')
                                     .where('communication_events.occurred_at >= ?', 7.days.ago)
                                     .count

    if direct_opens.positive?
      direct_open_points = direct_opens * ACTIVITY_SCORES['email_opened']
      breakdown['email_opened'] = { count: direct_opens, points: direct_open_points }
      total += direct_open_points
    end

    # Quote views — public quote token URLs (/q/...)
    if lead.respond_to?(:deals) || lead.respond_to?(:quotes)
      quote_views = CommunicationEvent.joins(:communication)
                                      .where(communications: { communicable_type: 'Lead', communicable_id: lead.id, channel: 'email' })
                                      .where(event_type: 'clicked')
                                      .where('communication_events.occurred_at >= ?', 30.days.ago)
                                      .where("communication_events.details IS NOT NULL AND (communication_events.details::jsonb)->>'url' LIKE '%/q/%'")
                                      .count

      if quote_views.positive?
        quote_points = quote_views * ACTIVITY_SCORES['quote_viewed']
        breakdown['quote_viewed'] = { count: quote_views, points: quote_points }
        total += quote_points
      end
    end

    capped = [total, ENGAGEMENT_CAP].min
    { total: capped, activities: breakdown, raw_total: total, capped_at: ENGAGEMENT_CAP }
  end

  def fit_score
    answers = lead.survey_answers || {}
    return { total: 0, matched: {} } if answers.blank?

    matched = {}
    total = 0

    # Timeline
    timeline = answers['timeline'] || answers['purchase_timeframe'] || lead.purchase_timeframe
    case timeline.to_s.downcase
    when 'asap', 'immediate', 'immediately', 'now'
      matched['timeline_asap'] = FIT_SCORES['timeline_asap']
      total += FIT_SCORES['timeline_asap']
    when '3_months', '3 months', '1_3_months'
      matched['timeline_3_months'] = FIT_SCORES['timeline_3_months']
      total += FIT_SCORES['timeline_3_months']
    when '6_months', '6 months', '3_6_months'
      matched['timeline_6_months'] = FIT_SCORES['timeline_6_months']
      total += FIT_SCORES['timeline_6_months']
    end

    # Has land
    if truthy?(answers['has_land']) || truthy?(answers['owns_land'])
      matched['has_land'] = FIT_SCORES['has_land']
      total += FIT_SCORES['has_land']
    end

    # Pre-qualified financing
    if truthy?(answers['financing_prequalified']) || truthy?(answers['prequalified'])
      matched['financing_prequal'] = FIT_SCORES['financing_prequal']
      total += FIT_SCORES['financing_prequal']
    end

    # Budget matches or stated
    if answers['budget'].present? || lead.budget_range.present?
      matched['budget_qualified'] = FIT_SCORES['budget_qualified']
      total += FIT_SCORES['budget_qualified']
    end

    { total: total, matched: matched }
  end

  def decay_penalty
    last = lead.last_activity_at || lead.updated_at
    return { total: 0, days_inactive: 0 } if last.blank?

    days = ((Time.current - last) / 1.day).to_i
    penalty =
      if    days >= 30 then 50
      elsif days >= 14 then 25
      elsif days >= 7  then 10
      else 0
      end

    { total: penalty, days_inactive: days }
  end

  def band_for(score)
    return 'dead' if score.negative?
    BANDS.each do |min, name|
      return name if score >= min
    end
    'cold'
  end

  def truthy?(value)
    return false if value.nil?
    return true if value == true
    %w[true yes y 1].include?(value.to_s.strip.downcase)
  end
end
