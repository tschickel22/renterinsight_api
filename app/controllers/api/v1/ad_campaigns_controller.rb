# frozen_string_literal: true

class Api::V1::AdCampaignsController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign, only: %i[show pause resume destroy]

  MAX_PER_PAGE = 100

  # GET /api/v1/ad-campaigns
  def index
    return unless authorize_action!('facebook_ads', 'read')

    campaigns = @company.ad_campaigns.active.order(created_at: :desc)
    total     = campaigns.count

    page     = [(params[:page] || 1).to_i, 1].max
    per_page = [[((params[:per_page] || 25).to_i), MAX_PER_PAGE].min, 1].max

    campaigns = campaigns.offset((page - 1) * per_page).limit(per_page)

    render json: {
      campaigns: campaigns.map { |c| serialize(c) },
      meta: {
        total:       total,
        page:        page,
        per_page:    per_page,
        total_pages: (total.to_f / per_page).ceil
      }
    }
  end

  # GET /api/v1/ad-campaigns/:id
  def show
    return unless authorize_action!('facebook_ads', 'read')
    @campaign.calculate_roi!
    render json: serialize(@campaign)
  end

  # POST /api/v1/ad-campaigns/launch
  # Simplified 3-step wizard that provisions campaign → adset → creative → ad on Meta.
  def launch
    return unless authorize_action!('facebook_ads', 'create')

    integration = @company.facebook_integrations.active.order(:id).first
    return render json: { error: 'Connect Facebook first in Settings > Integrations' }, status: :unprocessable_entity unless integration

    metadata = integration.metadata.to_h.deep_stringify_keys
    ad_account_id = metadata['ad_account_id']
    return render json: { error: 'No ad account linked. Connect your Facebook Ads account in Settings.' }, status: :unprocessable_entity if ad_account_id.blank?

    token = integration.page_access_token

    # Extract wizard params
    primary_text     = params[:primary_text].to_s
    headline_text    = params[:headline].to_s
    description_text = params[:description].to_s
    image_url        = params[:image_url].to_s
    link_url         = params[:link_url].to_s
    daily_budget     = params[:daily_budget].to_f
    duration_days    = [params[:duration_days].to_i, 1].max
    radius_miles     = (params[:radius_miles] || 50).to_i
    age_min          = (params[:age_min] || 25).to_i
    age_max          = (params[:age_max] || 65).to_i
    interests        = Array(params[:interests])
    objective        = params[:objective].presence || 'OUTCOME_LEADS'
    cta_type         = params[:cta_type].presence || 'LEARN_MORE'

    use_catalog   = ActiveModel::Type::Boolean.new.cast(params[:use_catalog])
    lead_form_id  = params[:lead_form_id].to_s.presence
    _topic_details = params[:topic_details] # accepted for client context; not forwarded to Meta

    # When a native FB Lead Form is attached, the CTA must be SIGN_UP and the
    # link_url is optional (Meta routes users into the in-FB form instead).
    if lead_form_id.present?
      cta_type = 'SIGN_UP'
    end

    return render json: { error: 'primary_text is required' }, status: :bad_request if primary_text.blank?
    return render json: { error: 'link_url is required' }, status: :bad_request     if link_url.blank? && lead_form_id.blank?
    return render json: { error: 'daily_budget must be > 0' }, status: :bad_request if daily_budget <= 0

    daily_budget_cents = (daily_budget * 100).to_i
    campaign_name = "RI: #{headline_text.presence&.truncate(40) || 'Ad'} - #{Date.current}"

    campaign_id = nil
    begin
      campaign_result = MetaGraphApi.create_campaign(
        ad_account_id, token,
        name:                  campaign_name,
        objective:             objective,
        status:                'PAUSED',
        special_ad_categories: ['HOUSING']
      )
      campaign_id = campaign_result['id']

      location = @company.locations.order(:id).first
      targeting = build_targeting(location: location, radius_miles: radius_miles,
                                  age_min: age_min, age_max: age_max, interests: interests)

      adset_result = MetaGraphApi.create_ad_set(
        ad_account_id, token,
        campaign_id:        campaign_id,
        name:               "RI AdSet: #{radius_miles}mi, #{age_min}-#{age_max}",
        daily_budget_cents: daily_budget_cents,
        targeting:          targeting,
        optimization_goal:  optimization_goal_for(objective),
        start_time:         Time.current.iso8601
      )
      adset_id = adset_result['id']

      creative_result = MetaGraphApi.create_ad_creative(
        ad_account_id, token,
        page_id:             integration.page_id,
        message:             primary_text,
        link:                link_url.presence || "https://www.facebook.com/#{integration.page_id}",
        image_url:           image_url.presence,
        headline:            headline_text.presence,
        description:         description_text.presence,
        call_to_action_type: cta_type,
        lead_form_id:        lead_form_id
      )
      creative_id = creative_result['id']

      ad_result = MetaGraphApi.create_ad(
        ad_account_id, token,
        ad_set_id:   adset_id,
        name:        "RI Ad: #{headline_text.presence&.truncate(50) || 'Ad'}",
        creative_id: creative_id
      )

      MetaGraphApi.update_campaign_status(campaign_id, token, status: 'ACTIVE')

      ad_campaign = @company.ad_campaigns.create!(
        external_campaign_id: campaign_id,
        name:                 campaign_name,
        objective:            objective,
        status:               'ACTIVE',
        daily_budget:         daily_budget,
        synced_at:            Time.current
      )

      notes = []
      if use_catalog
        notes << 'Catalog / Dynamic Ads selected. A static creative was launched for now — configure a product_catalog_id adset in Meta Ads Manager to switch to catalog-driven delivery.'
      end
      notes << "Attached Facebook Lead Form #{lead_form_id}." if lead_form_id.present?

      render json: {
        success:          true,
        campaign:         serialize(ad_campaign),
        meta_campaign_id: campaign_id,
        meta_adset_id:    adset_id,
        meta_ad_id:       ad_result['id'],
        use_catalog:      use_catalog,
        lead_form_id:     lead_form_id,
        message:          "Ad launched! Budget: $#{daily_budget}/day for #{duration_days} days.",
        notes:            notes
      }, status: :created

    rescue MetaGraphApi::ExpiredTokenError => e
      integration.update(status: 'expired')
      cleanup_campaign(campaign_id, token)
      render json: { error: "Facebook token expired: #{e.message}" }, status: :unprocessable_entity
    rescue MetaGraphApi::Error => e
      cleanup_campaign(campaign_id, token)
      render json: { error: "Failed to create ad: #{e.message}" }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/ad-campaigns/:id/pause
  def pause
    return unless authorize_action!('facebook_ads', 'update')
    apply_status_change!(@campaign, meta_status: 'PAUSED', local_status: 'PAUSED')
  end

  # POST /api/v1/ad-campaigns/:id/resume
  def resume
    return unless authorize_action!('facebook_ads', 'update')
    apply_status_change!(@campaign, meta_status: 'ACTIVE', local_status: 'ACTIVE')
  end

  # DELETE /api/v1/ad-campaigns/:id
  def destroy
    return unless authorize_action!('facebook_ads', 'delete')

    integration = @company.facebook_integrations.active.order(:id).first
    if integration
      begin
        MetaGraphApi.delete_campaign(@campaign.external_campaign_id, integration.page_access_token)
      rescue MetaGraphApi::Error => e
        Rails.logger.warn "[AdCampaigns#destroy] Meta delete failed (continuing): #{e.message}"
      end
    end

    @campaign.update!(status: 'DELETED', is_deleted: true)
    head :no_content
  end

  # GET /api/v1/ad-campaigns/lead-forms
  # Lists the Facebook Lead Forms available on the connected page.
  def lead_forms
    return unless authorize_action!('facebook_ads', 'read')

    integration = @company.facebook_integrations.active.order(:id).first
    return render json: { lead_forms: [], error: 'No Facebook page connected' } unless integration

    begin
      result = MetaGraphApi.get_lead_forms(integration.page_id, integration.page_access_token)
    rescue MetaGraphApi::ExpiredTokenError => e
      integration.update(status: 'expired')
      return render json: { lead_forms: [], error: "Facebook token expired: #{e.message}" }
    rescue MetaGraphApi::Error => e
      return render json: { lead_forms: [], error: e.message }
    end

    forms = Array(result['data']).map do |form|
      {
        id:           form['id'],
        name:         form['name'],
        status:       form['status'],
        leads_count:  form['leads_count'],
        created_time: form['created_time']
      }
    end

    render json: { lead_forms: forms }
  end

  # GET /api/v1/ad-campaigns/catalog-status
  # Reports whether Dynamic Ads via the Meta product catalog feed is ready.
  def catalog_status
    return unless authorize_action!('facebook_ads', 'read')

    has_token     = @company.meta_catalog_token.present?
    vehicle_count = @company.vehicles.where(is_deleted: false, status: 'available').count

    feed_url = nil
    if has_token
      base = ENV['API_BASE_URL'].presence || (request.respond_to?(:base_url) ? request.base_url : nil)
      feed_url = "#{base}/api/v1/meta/catalog/#{@company.id}/feed?token=#{@company.meta_catalog_token}"
    end

    render json: {
      enabled:       has_token,
      vehicle_count: vehicle_count,
      feed_url:      feed_url
    }
  end

  # GET /api/v1/ad-campaigns/roi_summary
  def roi_summary
    return unless authorize_action!('facebook_ads', 'read')

    campaigns = @company.ad_campaigns.active

    total_spend   = campaigns.sum(:spend).to_f
    total_leads   = campaigns.sum(:leads_count).to_i
    total_deals   = campaigns.sum(:deals_count).to_i
    total_revenue = campaigns.sum(:revenue).to_f

    render json: {
      total_spend:          total_spend,
      total_leads:          total_leads,
      total_deals:          total_deals,
      total_revenue:        total_revenue,
      overall_cost_per_lead: total_leads.positive? ? (total_spend / total_leads).round(2) : 0,
      overall_cost_per_deal: total_deals.positive? ? (total_spend / total_deals).round(2) : 0,
      overall_roi:          total_spend.positive? ? (((total_revenue - total_spend) / total_spend) * 100).round(2) : 0,
      campaign_count:       campaigns.count
    }
  end

  private

  def set_campaign
    @campaign = @company.ad_campaigns.active.find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @campaign
  end

  def apply_status_change!(campaign, meta_status:, local_status:)
    integration = @company.facebook_integrations.active.order(:id).first
    return render json: { error: 'No active Facebook integration' }, status: :unprocessable_entity unless integration

    begin
      MetaGraphApi.update_campaign_status(campaign.external_campaign_id, integration.page_access_token, status: meta_status)
    rescue MetaGraphApi::ExpiredTokenError => e
      integration.update(status: 'expired')
      return render json: { error: "Facebook token expired: #{e.message}" }, status: :unprocessable_entity
    rescue MetaGraphApi::Error => e
      return render json: { error: "Meta API error: #{e.message}" }, status: :unprocessable_entity
    end

    campaign.update!(status: local_status)
    render json: serialize(campaign)
  end

  def build_targeting(location:, radius_miles:, age_min:, age_max:, interests:)
    lat = location.respond_to?(:latitude)  ? location.latitude  : nil
    lng = location.respond_to?(:longitude) ? location.longitude : nil

    {
      geo_locations: {
        custom_locations: [{
          latitude:      lat || 39.7392,
          longitude:     lng || -104.9903,
          radius:        radius_miles,
          distance_unit: 'mile'
        }]
      },
      age_min: age_min,
      age_max: age_max
    }.tap do |t|
      # Interests come in as free-text; actual FB interest IDs would be
      # resolved by an interest-search call. Leaving as empty targeting for
      # now means Meta falls back to broad audience expansion.
      t[:flexible_spec] = [{ interests: interests.map { |i| { name: i } } }] if interests.any?
    end
  end

  def optimization_goal_for(objective)
    case objective.to_s
    when 'OUTCOME_LEADS', 'LEAD_GENERATION' then 'LEAD_GENERATION'
    when 'OUTCOME_TRAFFIC', 'TRAFFIC'       then 'LINK_CLICKS'
    when 'OUTCOME_AWARENESS'                then 'REACH'
    else 'LEAD_GENERATION'
    end
  end

  def cleanup_campaign(campaign_id, token)
    return if campaign_id.blank?
    MetaGraphApi.delete_campaign(campaign_id, token)
  rescue => e
    Rails.logger.warn "[AdCampaigns#launch] cleanup failed for campaign=#{campaign_id}: #{e.message}"
  end

  def serialize(c)
    {
      id:                   c.id,
      external_campaign_id: c.external_campaign_id,
      name:                 c.name,
      objective:            c.objective,
      status:               c.status,
      daily_budget:         c.daily_budget,
      lifetime_budget:      c.lifetime_budget,
      spend:                c.spend,
      impressions:          c.impressions,
      clicks:               c.clicks,
      reach:                c.reach,
      leads_count:          c.leads_count,
      deals_count:          c.deals_count,
      revenue:              c.revenue,
      cost_per_lead:        c.cost_per_lead,
      cost_per_deal:        c.cost_per_deal,
      roi_percentage:       c.roi_percentage,
      synced_at:            c.synced_at,
      created_at:           c.created_at,
      updated_at:           c.updated_at
    }
  end
end
