# frozen_string_literal: true

class Api::V1::Integrations::FacebookController < ApplicationController
  before_action :set_company_scope, except: [:callback]
  skip_before_action :authenticate, only: [:callback]

  SCOPES = %w[
    business_management
    leads_retrieval
    pages_read_engagement
    pages_manage_metadata
    pages_show_list
    pages_manage_posts
    ads_management
    ads_read
  ].freeze

  # Facebook Login for Business configuration ID
  # When set, uses config_id instead of scope (required for Business Login)
  FACEBOOK_LOGIN_CONFIG_ID = ENV['FACEBOOK_LOGIN_CONFIG_ID'] || '997880389376695'

  # GET /api/v1/integrations/facebook/authorize
  def authorize
    return unless authorize_action!('integrations', 'update')

    state = encrypt_state(
      company_id:  @company.id,
      location_id: params[:location_id],
      return_url:  params[:return_url],
      nonce:       SecureRandom.hex(16)
    )

    auth_url = URI("https://www.facebook.com/#{MetaGraphApi::API_VERSION}/dialog/oauth")

    query_params = {
      client_id:     MetaGraphApi.app_id,
      redirect_uri:  callback_redirect_uri,
      state:         state,
      response_type: 'code'
    }

    # login_type param: 'business' uses Facebook Login for Business (config_id)
    # 'classic' or default uses scope-based login
    # Business Login is for dealer customers connecting their business portfolio
    # Classic Login is for app owners or simple page connections
    use_business_login = params[:login_type] == 'business' && FACEBOOK_LOGIN_CONFIG_ID.present?

    if use_business_login
      query_params[:config_id] = FACEBOOK_LOGIN_CONFIG_ID
    else
      query_params[:scope] = SCOPES.join(',')
    end

    auth_url.query = URI.encode_www_form(query_params)

    render json: { authorize_url: auth_url.to_s }
  end

  # GET /api/v1/integrations/facebook/callback
  # (Exchanges code → user token, lists pages for selection)
  def callback
    state_data = decrypt_state(params[:state])
    return render json: { error: 'Invalid state token' }, status: :bad_request unless state_data

    company = Company.find_by(id: state_data['company_id'])
    return render json: { error: 'Company not found' }, status: :not_found unless company

    begin
      token_resp = MetaGraphApi.exchange_code_for_token(params[:code], callback_redirect_uri)
      short_lived = token_resp['access_token']

      long_lived_resp = MetaGraphApi.exchange_token(short_lived)
      user_access_token = long_lived_resp['access_token']
      expires_in        = long_lived_resp['expires_in']

      pages_response = MetaGraphApi.list_user_pages(user_access_token)
      Rails.logger.info "[FacebookOAuth] Raw pages response: #{pages_response.inspect[0..500]}"
      pages = pages_response['data'] || []
      Rails.logger.info "[FacebookOAuth] Pages returned from Graph API: #{pages.length} pages"
      pages.each { |p| Rails.logger.info "[FacebookOAuth]   Page: #{p['id']} - #{p['name']}" }

      # If /me/accounts returns empty, the user may have granted page access
      # but isn't a direct admin (common with Business Portfolio-owned pages).
      # Try fetching pages the user selected during OAuth via /me/accounts with
      # the short-lived token as well.
      if pages.empty?
        Rails.logger.info "[FacebookOAuth] No pages from long-lived token, trying short-lived..."
        short_pages = MetaGraphApi.list_user_pages(short_lived)['data'] || []
        Rails.logger.info "[FacebookOAuth] Short-lived token pages: #{short_pages.length}"
        pages = short_pages if short_pages.any?
      end

      # If still empty, return user_access_token so frontend can offer manual page ID entry
      if pages.empty?
        Rails.logger.info "[FacebookOAuth] Still no pages found. User may need to be a Page admin."
      end
    rescue MetaGraphApi::Error => e
      Rails.logger.error "[FacebookOAuth] callback error: #{e.message}"
      return render json: { error: e.message }, status: :unprocessable_entity
    end

    render json: {
      success:           true,
      company_id:        company.id,
      return_url:        state_data['return_url'],
      location_id:       state_data['location_id'],
      user_access_token: user_access_token,
      token_expires_at:  (Time.current + expires_in.to_i.seconds).iso8601,
      pages: pages.map { |p| { id: p['id'], name: p['name'], access_token: p['access_token'], category: p['category'], tasks: p['tasks'] } }
    }
  end

  # POST /api/v1/integrations/facebook/connect_page
  def connect_page
    return unless authorize_action!('integrations', 'update')

    page_id            = params[:page_id].to_s
    page_name          = params[:page_name].to_s
    page_access_token  = params[:page_access_token].to_s
    user_access_token  = params[:user_access_token].to_s
    location_id        = params[:location_id]

    return render json: { error: 'page_id required' }, status: :bad_request if page_id.blank?
    # If page_name wasn't provided, fetch it from Graph API
    if page_name.blank? && page_access_token.present?
      begin
        page_data = MetaGraphApi.get("/#{page_id}", page_access_token, fields: 'name')
        page_name = page_data['name'] if page_data.is_a?(Hash)
      rescue MetaGraphApi::Error => e
        Rails.logger.info "[FacebookOAuth] Could not fetch page name: #{e.message}"
      end
    end

    return render json: { error: 'page_access_token required' }, status: :bad_request if page_access_token.blank?

    begin
      MetaGraphApi.subscribe_page_to_webhooks(page_id, page_access_token)
    rescue MetaGraphApi::Error => e
      Rails.logger.error "[FacebookOAuth] subscribe_page_to_webhooks failed: #{e.message}"
      return render json: { error: "Subscribe failed: #{e.message}" }, status: :unprocessable_entity
    end

    default_source = Source.find_or_create_by!(company_id: @company.id, name: 'Facebook') do |s|
      s.source_type = 'paid_ad'
      s.is_active   = true
    end

    integration = @company.facebook_integrations.find_or_initialize_by(page_id: page_id)
    integration.assign_attributes(
      location_id:        location_id,
      page_name:          page_name.presence || integration.page_name,
      page_access_token:  page_access_token,
      user_access_token:  user_access_token.presence || integration.user_access_token,
      status:             'active',
      subscribed_fields:  ['leadgen'],
      default_source_id:  integration.default_source_id || default_source.id,
      default_owner_id:   integration.default_owner_id  || current_user&.id,
      is_deleted:         false
    )
    integration.save!

    capture_instagram_business_account!(integration)

    render json: { integration: serialize(integration).merge(metadata: integration.metadata) }, status: :ok
  end

  # GET /api/v1/integrations/facebook/status
  def status
    integrations = @company.facebook_integrations.active

    first_integration = integrations.first

    ig_meta = first_integration&.metadata.to_h.deep_stringify_keys
    ig_connected = ig_meta&.dig('instagram_business_account_id').present?

    render json: {
      connected: integrations.exists?,
      count:     integrations.count,
      integration_id: first_integration&.id,
      page_id:   first_integration&.page_id,
      page_name: first_integration&.page_name,
      token_expires_at: first_integration&.token_expires_at,
      token_expired: first_integration&.token_expires_at.present? && first_integration.token_expires_at < Time.current,
      instagram_connected: ig_connected,
      instagram_username: ig_connected ? ig_meta['instagram_username'] : nil,
      integrations: integrations.map { |i| serialize(i) }
    }
  end

  # DELETE /api/v1/integrations/facebook/disconnect
  def disconnect
    return unless authorize_action!('integrations', 'delete')

    integration = params[:id].present? ? 
      @company.facebook_integrations.find_by(id: params[:id]) :
      @company.facebook_integrations.where(is_deleted: [false, nil]).first
    return render json: { error: 'Integration not found' }, status: :not_found unless integration

    begin
      MetaGraphApi.unsubscribe_page_from_webhooks(integration.page_id, integration.page_access_token) if integration.page_access_token.present?
    rescue MetaGraphApi::Error => e
      Rails.logger.warn "[FacebookOAuth] unsubscribe failed: #{e.message}"
    end

    integration.update!(status: 'disconnected', is_deleted: true)
    render json: { success: true }
  end

  private

  # Stash the linked Instagram Business Account on the integration metadata so
  # the publisher can later post to Instagram without an extra round-trip.
  # Fails silently if the page has no IG linked or the token lacks scope.
  def capture_instagram_business_account!(integration)
    ig_data = MetaGraphApi.get(
      "/#{integration.page_id}",
      integration.page_access_token,
      fields: 'instagram_business_account{id,name,username,profile_picture_url}'
    )
    ig_account = ig_data.is_a?(Hash) ? ig_data['instagram_business_account'] : nil
    return unless ig_account.is_a?(Hash) && ig_account['id'].present?

    merged = integration.metadata.to_h.deep_stringify_keys.merge(
      'instagram_business_account_id' => ig_account['id'],
      'instagram_username'             => ig_account['username'],
      'instagram_profile_picture'      => ig_account['profile_picture_url']
    )
    integration.update!(metadata: merged)
  rescue MetaGraphApi::Error => e
    Rails.logger.info "[FacebookOAuth] no IG business account linked: #{e.message}"
  end

  def callback_redirect_uri
    frontend_url = ENV['FRONTEND_URL'] || 'https://localhost:5173'
    "#{frontend_url}/integrations/facebook/callback"
  end

  def state_encryptor
    ActiveSupport::MessageEncryptor.new(Rails.application.secret_key_base[0, 32])
  end

  def encrypt_state(hash)
    state_encryptor.encrypt_and_sign(hash.to_json)
  end

  def decrypt_state(token)
    JSON.parse(state_encryptor.decrypt_and_verify(token.to_s))
  rescue
    nil
  end

  def serialize(i)
    {
      id:                 i.id,
      page_id:            i.page_id,
      page_name:          i.page_name,
      status:             i.status,
      subscribed_fields:  i.subscribed_fields,
      field_mapping:      i.field_mapping,
      default_source_id:  i.default_source_id,
      default_owner_id:   i.default_owner_id,
      default_workflow_id: i.default_workflow_id,
      lead_count:         i.lead_count,
      last_lead_at:       i.last_lead_at,
      token_expires_at:   i.token_expires_at,
      created_at:         i.created_at,
      updated_at:         i.updated_at
    }
  end
end
