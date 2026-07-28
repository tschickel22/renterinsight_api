# frozen_string_literal: true

class Api::V1::AdCampaignsController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign, only: %i[show pause resume destroy ad_sets]

  MAX_PER_PAGE = 100

  # GET /api/v1/ad-campaigns
  def index
    return unless authorize_action!('facebook_ads', 'read')

    all_for_company = @company.ad_campaigns.active
    campaigns       = for_linked_ad_account(all_for_company).order(created_at: :desc)
    total           = campaigns.count

    page     = [(params[:page] || 1).to_i, 1].max
    per_page = [[((params[:per_page] || 25).to_i), MAX_PER_PAGE].min, 1].max

    campaigns = campaigns.offset((page - 1) * per_page).limit(per_page)

    render json: {
      campaigns: campaigns.map { |c| serialize(c) },
      meta: {
        total:       total,
        page:        page,
        per_page:    per_page,
        total_pages: (total.to_f / per_page).ceil,
        # An empty list means something different depending on whether we hold
        # nothing at all or only rows from a previously-linked account. The tab
        # can then say "sync" instead of "create your first ad".
        ad_account_id:        linked_ad_account_id,
        other_account_total:  total.zero? ? all_for_company.count : 0,
        never_synced:         all_for_company.where.not(synced_at: nil).none?
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

    integration = FacebookIntegration.current_for(@company)
    return render json: { error: 'Connect Facebook first in Settings > Integrations' }, status: :unprocessable_entity unless integration

    metadata = integration.metadata.to_h.deep_stringify_keys
    ad_account_id = metadata['ad_account_id']
    return render json: { error: 'No ad account linked. Connect your Facebook Ads account in Settings.' }, status: :unprocessable_entity if ad_account_id.blank?

    # Ad-account endpoints (campaigns/adsets/creatives/ads) require a user token
    # carrying ads_management — a Page token is only good for Page objects, and
    # spending money on a call Meta will reject deserves a clear error up front.
    token = integration.user_access_token
    if token.blank?
      return render json: { error: 'Reconnect Facebook in Settings to grant ads access — this connection has no user token.' },
                    status: :unprocessable_entity
    end

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
    cta_type         = normalize_cta_type(params[:cta_type])

    use_catalog   = ActiveModel::Type::Boolean.new.cast(params[:use_catalog])
    lead_form_id  = params[:lead_form_id].to_s.presence
    _topic_details = params[:topic_details] # accepted for client context; not forwarded to Meta

    # When a native FB Lead Form is attached, the CTA must be SIGN_UP and the
    # link_url is optional (Meta routes users into the in-FB form instead).
    if lead_form_id.present?
      cta_type = 'SIGN_UP'
    end

    objective = normalize_objective(params[:objective])
    special_ad_categories = normalize_special_ad_categories(params[:special_ad_categories])

    # Optimising for leads needs somewhere to capture them — a native Facebook
    # form, or a conversion pixel we don't provision. With only a website link
    # Meta rejects the ad set, so send those to traffic, which is what the ad
    # actually does: click through to the intake form.
    objective = 'OUTCOME_TRAFFIC' if objective == 'OUTCOME_LEADS' && lead_form_id.blank?

    # Attach to an existing campaign/ad set instead of creating a new one. Every
    # ad in its own ad set restarts Meta's learning phase and makes the budgets
    # bid against each other, so reusing one is usually the better default.
    existing_campaign_id = params[:meta_campaign_id].to_s.presence
    existing_adset_id    = params[:meta_adset_id].to_s.presence

    return render json: { error: 'primary_text is required' }, status: :bad_request if primary_text.blank?
    return render json: { error: 'link_url is required' }, status: :bad_request     if link_url.blank? && lead_form_id.blank?
    if existing_adset_id.blank? && daily_budget <= 0
      return render json: { error: 'daily_budget must be > 0' }, status: :bad_request
    end

    daily_budget_cents = (daily_budget * 100).to_i
    campaign_name = "RI: #{headline_text.presence&.truncate(40) || 'Ad'} - #{Date.current}"

    campaign_id       = existing_campaign_id
    created_campaign  = false
    adset_id          = existing_adset_id
    # Four Meta calls behind one button — naming the failing step turns
    # "Failed to create ad" into something a user can act on.
    step = 'campaign'
    begin
      if campaign_id.blank?
        campaign_result = MetaGraphApi.create_campaign(
          ad_account_id, token,
          name:                  campaign_name,
          objective:             objective,
          status:                'PAUSED',
          special_ad_categories: special_ad_categories
        )
        campaign_id      = campaign_result['id']
        created_campaign = true
      end

      if adset_id.blank?
        location = @company.locations.order(:id).first
        targeting = build_targeting(location: location, radius_miles: radius_miles,
                                    age_min: age_min, age_max: age_max, interests: interests)

        step = 'ad set (budget, schedule and targeting)'
        adset_result = MetaGraphApi.create_ad_set(
          ad_account_id, token,
          campaign_id:        campaign_id,
          name:               "RI AdSet: #{radius_miles}mi, #{age_min}-#{age_max}",
          daily_budget_cents: daily_budget_cents,
          targeting:          targeting,
          optimization_goal:  optimization_goal_for(objective),
          # LEAD_GENERATION optimisation only validates when Meta knows which Page
          # hosts the instant form.
          promoted_object:    (lead_form_id.present? ? { page_id: integration.page_id } : nil),
          start_time:         Time.current.iso8601,
          # The wizard quotes a total spend off duration; without this the ad
          # set has no stop date and bills daily until someone notices.
          end_time:           duration_days.days.from_now.iso8601
        )
        adset_id = adset_result['id']
      end

      step = 'creative (text, image and link)'
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

      step = 'ad'
      ad_result = MetaGraphApi.create_ad(
        ad_account_id, token,
        ad_set_id:   adset_id,
        name:        "RI Ad: #{headline_text.presence&.truncate(50) || 'Ad'}",
        creative_id: creative_id
      )

      # Only activate a campaign we created. Joining an existing one must not
      # flip a paused campaign live behind the user's back.
      MetaGraphApi.update_campaign_status(campaign_id, token, status: 'ACTIVE') if created_campaign

      ad_campaign = @company.ad_campaigns.find_or_initialize_by(external_campaign_id: campaign_id)
      ad_campaign.assign_attributes(
        name:          created_campaign ? campaign_name : ad_campaign.name.presence || campaign_name,
        objective:     created_campaign ? objective : ad_campaign.objective.presence || objective,
        status:        created_campaign ? 'ACTIVE' : ad_campaign.status.presence || 'ACTIVE',
        daily_budget:  created_campaign ? daily_budget : ad_campaign.daily_budget,
        created_via:   ad_campaign.persisted? ? ad_campaign.created_via : 'dealertide',
        ad_account_id: ad_account_id,
        is_deleted:    false,
        synced_at:     Time.current
      )
      ad_campaign.save!

      notes = []
      if use_catalog
        notes << 'Catalog / Dynamic Ads selected. A static creative was launched for now — configure a product_catalog_id adset in Meta Ads Manager to switch to catalog-driven delivery.'
      end
      notes << "Attached Facebook Lead Form #{lead_form_id}." if lead_form_id.present?
      notes << 'Added to the existing campaign — its objective and special ad category apply.' if existing_campaign_id.present?
      notes << 'Added to the existing ad set, so it shares that budget, schedule and targeting.' if existing_adset_id.present?
      if interests.any? && existing_adset_id.blank?
        notes << 'Interests were not applied — Meta needs its own interest IDs, so this ad set runs broad targeting.'
      end

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
      cleanup_campaign(campaign_id, token) if created_campaign
      render json: { error: "Facebook token expired: #{e.message}" }, status: :unprocessable_entity
    rescue MetaGraphApi::Error => e
      # Only roll back a campaign this request created — deleting the campaign
      # the user asked to join would destroy live ads.
      cleanup_campaign(campaign_id, token) if created_campaign
      Rails.logger.error "[AdCampaigns#launch] company=#{@company.id} step=#{step} " \
                         "objective=#{objective} categories=#{special_ad_categories.inspect} " \
                         "budget_cents=#{daily_budget_cents} error=#{e.message}"
      render json: { error: "Failed at the #{step} step: #{e.message}" }, status: :unprocessable_entity
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

    integration = FacebookIntegration.current_for(@company)
    if integration
      begin
        MetaGraphApi.delete_campaign(@campaign.external_campaign_id, ads_token_for(integration))
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

    integration = FacebookIntegration.current_for(@company)
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

  # GET /api/v1/ad-campaigns/:id/ad_sets
  # Ad sets on an existing campaign, so a new creative can join one instead of
  # every ad getting its own campaign (which restarts Meta's learning phase and
  # splits the budget against itself).
  def ad_sets
    return unless authorize_action!('facebook_ads', 'read')

    integration = FacebookIntegration.current_for(@company)
    return render json: { ad_sets: [], error: 'Connect Facebook first' } unless integration

    token = integration.user_access_token
    return render json: { ad_sets: [], error: 'Reconnect Facebook to grant ads access.' } if token.blank?

    begin
      result = MetaGraphApi.get_ad_sets(@campaign.external_campaign_id, token)
    rescue MetaGraphApi::ExpiredTokenError => e
      integration.update(status: 'expired')
      return render json: { ad_sets: [], error: "Facebook token expired: #{e.message}" }
    rescue MetaGraphApi::Error => e
      return render json: { ad_sets: [], error: e.message }
    end

    ad_sets = Array(result['data']).map do |a|
      {
        id:                a['id'],
        name:              a['name'],
        status:            a['status'],
        daily_budget:      a['daily_budget'].present? ? (a['daily_budget'].to_f / 100.0) : nil,
        optimization_goal: a['optimization_goal']
      }
    end

    render json: { ad_sets: ad_sets, campaign_objective: @campaign.objective }
  end

  # GET /api/v1/ad-campaigns/ad_options
  # Drives the Ad Builder's category picker: the full list plus what we suggest
  # for this tenant's industry.
  def ad_options
    return unless authorize_action!('facebook_ads', 'read')

    render json: {
      special_ad_categories: Company::SPECIAL_AD_CATEGORIES.map { |value, label| { value: value, label: label } },
      suggested_special_ad_category: @company.suggested_special_ad_category,
      industry: @company.industry
    }
  end

  # POST /api/v1/ad-campaigns/sync
  # On-demand version of the nightly SyncAdSpendJob — pulls every campaign on the
  # linked ad account, including ones created straight in Meta Ads Manager.
  def sync
    return unless authorize_action!('facebook_ads', 'read')

    result = MetaAdSpendService.sync_for_company(@company)

    if result[:skipped].present?
      return render json: { synced: 0, error: sync_skip_message(result[:skipped], result[:error]) },
                    status: :unprocessable_entity
    end

    @company.ad_campaigns.active.find_each do |campaign|
      campaign.calculate_roi!
    rescue => e
      Rails.logger.error "[AdCampaigns#sync] roi recalc failed campaign=#{campaign.id}: #{e.message}"
    end

    render json: { synced: result[:synced].to_i, synced_at: Time.current }
  end

  # GET /api/v1/ad-campaigns/roi_summary
  def roi_summary
    return unless authorize_action!('facebook_ads', 'read')

    campaigns = for_linked_ad_account(@company.ad_campaigns.active)

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

  # The Ads tab reports on the ad account that's currently linked. Campaigns
  # stamped with a different account came from a previous selection and would
  # otherwise linger forever — the sync upserts but never retires rows. Rows
  # predating the stamp are null; the next sync re-stamps the real ones.
  def for_linked_ad_account(scope)
    ad_account_id = linked_ad_account_id
    return scope if ad_account_id.blank?

    scope.where(ad_account_id: ad_account_id)
  end

  def linked_ad_account_id
    integration = FacebookIntegration.current_for(@company)
    return nil unless integration

    integration.metadata.to_h.deep_stringify_keys['ad_account_id'].presence
  end

  def set_campaign
    @campaign = @company.ad_campaigns.active.find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @campaign
  end

  def sync_skip_message(reason, detail)
    case reason.to_s
    when 'no_integration' then 'Connect Facebook first in Settings > Integrations'
    when 'no_ad_account'  then 'No ad account linked. Pick one in Settings > Integrations.'
    when 'expired_token'  then 'Facebook token expired — reconnect in Settings > Integrations.'
    else detail.presence || 'Could not reach Meta.'
    end
  end

  # Ads live on the ad account, not the Page, so they need the user token.
  # Fall back to the Page token for legacy connections rather than hard-failing
  # status changes that may still work.
  def ads_token_for(integration)
    integration.user_access_token.presence || integration.page_access_token.presence
  end

  def apply_status_change!(campaign, meta_status:, local_status:)
    integration = FacebookIntegration.current_for(@company)
    return render json: { error: 'No active Facebook integration' }, status: :unprocessable_entity unless integration

    begin
      MetaGraphApi.update_campaign_status(campaign.external_campaign_id, ads_token_for(integration), status: meta_status)
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
    }
    # Interests arrive as free text. Meta's flexible_spec needs interest *ids*
    # from its targeting-search endpoint and rejects name-only entries, so
    # sending them would fail the whole ad set. Broad targeting is the honest
    # fallback until interest lookup exists — launch surfaces a note saying so.
  end

  # Campaigns created on the current Graph API must use ODAX ("OUTCOME_*")
  # objectives. The legacy names still appear in Meta's own error text, which is
  # why sending LEAD_GENERATION comes back as the misleading "Objective is
  # invalid" listing a set that appears to contain it.
  LEGACY_OBJECTIVE_MAP = {
    'LEAD_GENERATION'       => 'OUTCOME_LEADS',
    'LINK_CLICKS'           => 'OUTCOME_TRAFFIC',
    'TRAFFIC'               => 'OUTCOME_TRAFFIC',
    'REACH'                 => 'OUTCOME_AWARENESS',
    'BRAND_AWARENESS'       => 'OUTCOME_AWARENESS',
    'LOCAL_AWARENESS'       => 'OUTCOME_AWARENESS',
    'POST_ENGAGEMENT'       => 'OUTCOME_ENGAGEMENT',
    'PAGE_LIKES'            => 'OUTCOME_ENGAGEMENT',
    'EVENT_RESPONSES'       => 'OUTCOME_ENGAGEMENT',
    'VIDEO_VIEWS'           => 'OUTCOME_ENGAGEMENT',
    'MESSAGES'              => 'OUTCOME_ENGAGEMENT',
    'CONVERSIONS'           => 'OUTCOME_SALES',
    'PRODUCT_CATALOG_SALES' => 'OUTCOME_SALES',
    'STORE_VISITS'          => 'OUTCOME_AWARENESS',
    'APP_INSTALLS'          => 'OUTCOME_APP_PROMOTION'
  }.freeze

  VALID_OBJECTIVES = %w[
    OUTCOME_AWARENESS OUTCOME_ENGAGEMENT OUTCOME_LEADS
    OUTCOME_SALES OUTCOME_TRAFFIC OUTCOME_APP_PROMOTION
  ].freeze

  # Accepts an array, a single string, or 'NONE'/'' meaning "not a regulated
  # vertical". Unknown values are dropped rather than forwarded — Meta rejects
  # the whole campaign on a bad category.
  def normalize_special_ad_categories(raw)
    return Array(@company.suggested_special_ad_category) if raw.nil?

    Array(raw)
      .map { |v| v.to_s.strip.upcase }
      .reject { |v| v.blank? || v == 'NONE' }
      .select { |v| Company::SPECIAL_AD_CATEGORIES.key?(v) }
      .uniq
  end

  # Meta's call_to_action types are upper-case constants. The wizard sends
  # lower-case option values, which Meta rejects with a 200-item list of what it
  # would have accepted — so normalise here rather than trusting the client.
  VALID_CTA_TYPES = %w[
    LEARN_MORE GET_QUOTE CONTACT_US APPLY_NOW SHOP_NOW SIGN_UP SUBSCRIBE
    BOOK_TRAVEL DOWNLOAD GET_DIRECTIONS GET_OFFER GET_SHOWTIMES LISTEN_NOW
    MESSAGE_PAGE NO_BUTTON ORDER_NOW PLAY_GAME REQUEST_TIME SAY_THANKS
    SEE_MORE SEND_MESSAGE WATCH_MORE WHATSAPP_MESSAGE BOOK_NOW CALL_NOW
    DONATE_NOW GET_IN_TOUCH INQUIRE_NOW MAKE_AN_APPOINTMENT REGISTER_NOW
    BUY_NOW SEE_DETAILS TRY_NOW
  ].freeze

  def normalize_cta_type(raw)
    value = raw.to_s.strip.upcase
    return 'LEARN_MORE' if value.blank?

    VALID_CTA_TYPES.include?(value) ? value : 'LEARN_MORE'
  end

  def normalize_objective(raw)
    value = raw.to_s.strip.upcase
    return 'OUTCOME_LEADS' if value.blank?

    mapped = LEGACY_OBJECTIVE_MAP[value] || value
    VALID_OBJECTIVES.include?(mapped) ? mapped : 'OUTCOME_LEADS'
  end

  def optimization_goal_for(objective)
    case objective.to_s
    when 'OUTCOME_LEADS'         then 'LEAD_GENERATION'
    when 'OUTCOME_TRAFFIC'       then 'LINK_CLICKS'
    when 'OUTCOME_AWARENESS'     then 'REACH'
    when 'OUTCOME_ENGAGEMENT'    then 'POST_ENGAGEMENT'
    when 'OUTCOME_SALES'         then 'OFFSITE_CONVERSIONS'
    else 'LINK_CLICKS'
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
      created_via:          c.created_via,
      synced_at:            c.synced_at,
      created_at:           c.created_at,
      updated_at:           c.updated_at
    }
  end
end
