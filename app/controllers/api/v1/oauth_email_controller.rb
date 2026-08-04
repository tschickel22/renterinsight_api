# frozen_string_literal: true

class Api::V1::OauthEmailController < ApplicationController
  REDIRECT_URI = "#{ENV.fetch('RAILS_API_URL', ENV.fetch('RAILS_BASE_URL', 'https://localhost:3001'))}/api/v1/oauth-email/callback"
  # Resolved at class-load (eager-loaded by `rails runner`, etc.) — must never raise,
  # or the cron jobs / boot itself dies. Falls back through APP_URL to a sane prod
  # default before localhost so a missing env var doesn't take down the app.
  FRONTEND_URL = ENV.fetch('FRONTEND_URL') do
    ENV.fetch('APP_URL') do
      Rails.env.production? ? 'https://dms.renterinsight.com' : 'https://localhost:5173'
    end
  end

  skip_before_action :authenticate, only: [:callback]
  before_action :set_company_scope, except: [:callback]
  before_action :authorize_shared_scope!, only: [:authorize, :disconnect]

  # GET /api/v1/oauth-email/authorize
  def authorize
    provider = params[:provider]
    return render json: { error: 'Invalid provider' }, status: :bad_request unless %w[microsoft google].include?(provider)

    scope_type = params[:scope_type]
    scope_id   = params[:scope_id]
    return_url = params[:return_url]

    client_id = ENV["#{provider.upcase}_OAUTH_CLIENT_ID"] ||
                Rails.application.credentials.dig(:oauth, provider.to_sym, :client_id)
    return render json: { error: "#{provider} OAuth not configured" }, status: :unprocessable_entity if client_id.blank?

    key       = Rails.application.secret_key_base[0..31]
    encryptor = ActiveSupport::MessageEncryptor.new(key)

    # Capture the *active session* company at authorize time. current_user.company_id
    # is the user's home company, which differs from the active company when a
    # platform admin is proxied into a tenant (X-Company-Id header / JWT override).
    # The connection must be persisted under the session's company, not the user's.
    state_data = {
      provider:   provider,
      scope_type: scope_type,
      scope_id:   scope_id,
      return_url: return_url,
      user_id:    current_user.id,
      company_id: @company&.id,
      nonce:      SecureRandom.hex(8)
    }
    state = Base64.urlsafe_encode64(encryptor.encrypt_and_sign(state_data.to_json))

    url = case provider
          when 'microsoft'
            base = 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize'
            query = {
              client_id:     client_id,
              response_type: 'code',
              redirect_uri:  REDIRECT_URI,
              scope:         'offline_access https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read',
              state:         state,
              response_mode: 'query'
            }
            "#{base}?#{URI.encode_www_form(query)}"
          when 'google'
            base = 'https://accounts.google.com/o/oauth2/v2/auth'
            query = {
              client_id:     client_id,
              response_type: 'code',
              redirect_uri:  REDIRECT_URI,
              scope:         'https://mail.google.com/ https://www.googleapis.com/auth/userinfo.email',
              access_type:   'offline',
              prompt:        'consent',
              state:         state
            }
            "#{base}?#{URI.encode_www_form(query)}"
          end

    render json: { auth_url: url }
  end

  # GET /api/v1/oauth-email/callback (PUBLIC)
  def callback
    if params[:error].present?
      return redirect_to "#{FRONTEND_URL}/oauth/email/callback?success=false&error=#{URI.encode_www_form_component(params[:error_description] || params[:error])}",
                         allow_other_host: true
    end

    begin
      key        = Rails.application.secret_key_base[0..31]
      encryptor  = ActiveSupport::MessageEncryptor.new(key)
      state_data = JSON.parse(encryptor.decrypt_and_verify(Base64.urlsafe_decode64(params[:state])))

      provider      = state_data['provider']
      scope_type    = state_data['scope_type']
      scope_id      = state_data['scope_id']
      client_id     = ENV["#{provider.upcase}_OAUTH_CLIENT_ID"] ||
                      Rails.application.credentials.dig(:oauth, provider.to_sym, :client_id)
      client_secret = ENV["#{provider.upcase}_OAUTH_CLIENT_SECRET"] ||
                      Rails.application.credentials.dig(:oauth, provider.to_sym, :client_secret)

      # Exchange code for tokens
      token_url = case provider
                  when 'microsoft' then 'https://login.microsoftonline.com/common/oauth2/v2.0/token'
                  when 'google'    then 'https://oauth2.googleapis.com/token'
                  end

      token_params = {
        client_id:     client_id,
        client_secret: client_secret,
        code:          params[:code],
        redirect_uri:  REDIRECT_URI,
        grant_type:    'authorization_code'
      }
      # Microsoft requires scope in the token exchange when multiple resource domains are used
      if provider == 'microsoft'
        token_params[:scope] = 'offline_access https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read'
      end

      tokens = http_post_form(token_url, token_params)

      Rails.logger.info "[OAuthEmail] Token exchange response keys: #{tokens.keys.inspect}"
      Rails.logger.info "[OAuthEmail] Token exchange error: #{tokens['error'].inspect} - #{tokens['error_description'].inspect}" if tokens['error'].present?
      Rails.logger.info "[OAuthEmail] access_token present: #{tokens['access_token'].present?}, refresh_token present: #{tokens['refresh_token'].present?}, id_token present: #{tokens['id_token'].present?}"

      if tokens['error'].present? || tokens['access_token'].blank?
        error_msg = tokens['error_description'] || tokens['error'] || 'Token exchange failed'
        raise StandardError, error_msg
      end

      # Get user email
      email = case provider
              when 'microsoft'
                extracted = nil

                # Strategy 1: Decode access_token JWT (always works - contains upn/unique_name)
                begin
                  padded = tokens['access_token'].split('.')[1].then { |s| s + '=' * ((4 - s.length % 4) % 4) }
                  at_claims = JSON.parse(Base64.urlsafe_decode64(padded))
                  Rails.logger.info "[OAuthEmail] Access token claims: upn=#{at_claims['upn'].inspect} unique_name=#{at_claims['unique_name'].inspect}"
                  extracted = at_claims['upn'].presence || at_claims['unique_name'].presence
                rescue => e
                  Rails.logger.warn "[OAuthEmail] Access token decode failed: #{e.message}"
                end

                # Strategy 2: MS Graph API
                if extracted.blank?
                  user_info = http_get('https://graph.microsoft.com/v1.0/me', tokens['access_token'])
                  Rails.logger.info "[OAuthEmail] MS Graph response: #{user_info.inspect}"
                  extracted = user_info['mail'].presence || user_info['userPrincipalName'].presence
                end

                # Strategy 3: id_token JWT
                if extracted.blank? && tokens['id_token'].present?
                  begin
                    padded = tokens['id_token'].split('.')[1].then { |s| s + '=' * ((4 - s.length % 4) % 4) }
                    id_claims = JSON.parse(Base64.urlsafe_decode64(padded))
                    Rails.logger.info "[OAuthEmail] id_token claims: #{id_claims.slice('email', 'preferred_username', 'upn').inspect}"
                    extracted = id_claims['email'].presence || id_claims['preferred_username'].presence || id_claims['upn'].presence
                  rescue => e
                    Rails.logger.warn "[OAuthEmail] id_token decode failed: #{e.message}"
                  end
                end

                extracted
              when 'google'
                extracted = nil

                # Strategy 1: userinfo API
                begin
                  user_info = http_get('https://www.googleapis.com/oauth2/v2/userinfo', tokens['access_token'])
                  Rails.logger.info "[OAuthEmail] Google userinfo response: #{user_info.inspect}"
                  extracted = user_info['email'].presence
                rescue => e
                  Rails.logger.warn "[OAuthEmail] Google userinfo failed: #{e.message}"
                end

                # Strategy 2: id_token JWT (Google always includes this)
                if extracted.blank? && tokens['id_token'].present?
                  begin
                    padded = tokens['id_token'].split('.')[1].then { |s| s + '=' * ((4 - s.length % 4) % 4) }
                    id_claims = JSON.parse(Base64.urlsafe_decode64(padded))
                    Rails.logger.info "[OAuthEmail] Google id_token claims: #{id_claims.slice('email', 'sub').inspect}"
                    extracted = id_claims['email'].presence
                  rescue => e
                    Rails.logger.warn "[OAuthEmail] Google id_token decode failed: #{e.message}"
                  end
                end

                extracted
              end

      Rails.logger.info "[OAuthEmail] Extracted email: #{email.inspect}"

      oauth_attrs = {
        'provider'          => "oauth_#{provider}",
        'oauthProvider'     => provider,
        'oauthAccessToken'  => tokens['access_token'],
        'oauthRefreshToken' => tokens['refresh_token'],
        'oauthExpiresAt'    => (Time.current + tokens['expires_in'].to_i.seconds).iso8601,
        'oauthEmail'        => email,
        'oauthConnectedAt'  => Time.current.iso8601,
        'isEnabled'         => true,
        'fromEmail'         => email,
        'fromName'          => email
      }

      Rails.logger.info "[OAuthEmail] oauth_attrs being saved: #{oauth_attrs.inspect}"

      merge_communications_setting(scope_type, scope_id, oauth_attrs, state_data['user_id'])

      # For user_email_connection scope: also create/update a UserEmailConnection record
      # so the EmailConnectionsTab UI (which reads UserEmailConnection model) shows it
      if scope_type == 'user_email_connection' && email.present?
        upsert_user_email_connection(
          user_id:       state_data['user_id'],
          company_id:    state_data['company_id'],
          email:         email,
          provider:      provider,
          access_token:  tokens['access_token'],
          refresh_token: tokens['refresh_token'],
          expires_at:    Time.current + tokens['expires_in'].to_i.seconds,
          # What was actually consented to, which can be narrower than what we
          # asked for. Capabilities are derived from this, never from the
          # provider name.
          granted_scopes: tokens['scope']
        )
      end

      # Use the return_url stored in state so the user lands back where they started
      return_url = state_data['return_url'].presence || '/account-settings?tab=email'
      redirect_to "#{FRONTEND_URL}/oauth/email/callback?success=true&provider=#{URI.encode_www_form_component(provider)}&email=#{URI.encode_www_form_component(email.to_s)}&return_url=#{URI.encode_www_form_component(return_url)}",
                  allow_other_host: true
    rescue => e
      Rails.logger.error "[OAuthEmail Callback] #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      # Pass return_url even on error so user lands back where they started
      return_url_param = return_url.present? ? "&return_url=#{URI.encode_www_form_component(return_url)}" : ''
      redirect_to "#{FRONTEND_URL}/oauth/email/callback?success=false&error=#{URI.encode_www_form_component(e.message)}#{return_url_param}",
                  allow_other_host: true
    end
  end

  # DELETE /api/v1/oauth-email/disconnect
  def disconnect
    scope_type = params[:scope_type]
    scope_id   = params[:scope_id]

    reset_attrs = {
      'provider'          => 'smtp',
      'oauthProvider'     => nil,
      'oauthAccessToken'  => nil,
      'oauthRefreshToken' => nil,
      'oauthExpiresAt'    => nil,
      'oauthEmail'        => nil,
      'oauthConnectedAt'  => nil
    }

    merge_communications_setting(scope_type, scope_id, reset_attrs, current_user.id)

    render json: { success: true }
  end

  private

  # Connecting a mailbox at platform/company/location scope makes that ONE
  # person's inbox the From address for everything the tenant sends that falls
  # through the waterfall — lead alerts, notifications, campaigns. That is an
  # admin-level act, so it must not be reachable by any authenticated user.
  # 'user_email_connection' scope stays open: that's a rep wiring up their own
  # mailbox, and it only ever affects mail they personally send.
  #
  # Previously this controller had no authorization at all beyond
  # set_company_scope, which is how a sales rep's personal mailbox ended up as
  # a company-wide sender.
  SHARED_SCOPES = %w[platform company location].freeze

  def authorize_shared_scope!
    scope_type = params[:scope_type].to_s
    return unless SHARED_SCOPES.include?(scope_type)

    if scope_type == 'platform'
      return if current_user.platform_admin? || current_user.super_admin?
      Rails.logger.warn "[OAuthEmail] User #{current_user.id} denied #{scope_type}-scope mailbox change"
      return render json: {
        error: 'Permission denied: only platform administrators can change the platform sending mailbox'
      }, status: :forbidden
    end

    return if current_user.effective_admin?

    Rails.logger.warn "[OAuthEmail] User #{current_user.id} denied #{scope_type}-scope mailbox change for company #{@company&.id}"
    render json: {
      error: 'Permission denied: only company administrators can change the shared sending mailbox'
    }, status: :forbidden
  end

  def upsert_user_email_connection(user_id:, company_id:, email:, provider:, access_token:, refresh_token:, expires_at:, granted_scopes: nil)
    user = User.find_by(id: user_id)
    return unless user

    # Resolve the company under which to persist this connection: prefer the active
    # session company captured in the OAuth state, fall back to the user's home
    # company only if state didn't carry one (older auth links). NEVER silently
    # rebind across companies.
    target_company_id = company_id.presence || user.company_id
    return unless target_company_id

    provider_value = provider == 'microsoft' ? 'oauth_outlook' : 'oauth_gmail'

    # Scope the upsert lookup to (user, company, provider). Without the company
    # scope, connecting OAuth while proxied into company 5 would update the
    # user's existing company-1 connection — moving credentials across tenants.
    scope = user.user_email_connections.where(company_id: target_company_id)
    connection = scope.find_by(provider: provider_value) ||
                 scope.find_by(email_address: email)

    # NB: display_name is intentionally not set here. It used to default to the
    # user's email, which (a) clobbered any UI-set display_name on every re-auth
    # and (b) made the email_senders picker show emails instead of names.
    # The picker now derives the label from User#first_name/last_name and
    # treats display_name as an optional override only.
    attrs = {
      email_address:              email,
      provider:                   provider_value,
      oauth_provider:             provider,
      is_active:                  true,
      verified_at:                Time.current,
      oauth_token_encrypted:      access_token,
      oauth_refresh_token_encrypted: refresh_token,
      oauth_expires_at:           expires_at
    }
    # Only overwrite on a grant that actually reported scopes. A provider that
    # omits the field must not wipe what we already knew about the connection.
    attrs[:oauth_scopes] = granted_scopes if granted_scopes.present?

    if connection
      connection.update!(attrs)
      Rails.logger.info "[OAuthEmail] Updated UserEmailConnection #{connection.id} for user #{user_id} in company #{target_company_id}"
    else
      is_first = scope.count.zero?
      # Pass company_id explicitly so the model's set_company_from_user callback
      # (which uses ||=) won't fall back to user.company_id.
      connection = user.user_email_connections.create!(
        attrs.merge(company_id: target_company_id, is_default: is_first)
      )
      Rails.logger.info "[OAuthEmail] Created UserEmailConnection #{connection.id} for user #{user_id} in company #{target_company_id}"
    end
  rescue => e
    Rails.logger.error "[OAuthEmail] Failed to upsert UserEmailConnection: #{e.message}\n#{e.backtrace&.first(3)&.join('\n')}"
  end

  def merge_communications_setting(scope_type, scope_id, email_attrs, user_id)
    scope_class, id = case scope_type
                      when 'platform'              then ['Platform', nil]
                      when 'company'               then ['Company',  scope_id]
                      when 'location'              then ['Location', scope_id]
                      when 'user_email_connection'  then ['User',    user_id]
                      end

    existing       = Setting.get(scope_class, id, 'communications') || {}
    existing_email = (existing['email'] || existing[:email] || {}).stringify_keys
    # Use compact only for disconnect (nil values = intentional clear)
    # For connect, we want to keep oauthEmail even if somehow nil so it's visible in logs
    new_attrs      = email_attrs.stringify_keys
    is_disconnect  = new_attrs['provider'] == 'smtp'
    merged_email   = is_disconnect ? existing_email.merge(new_attrs).compact : existing_email.merge(new_attrs)
    merged_comms   = existing.stringify_keys.merge('email' => merged_email)

    Setting.set(scope_class, id, 'communications', merged_comms)
  end

  def http_get(url, bearer_token)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{bearer_token}"
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    JSON.parse(res.body)
  end

  def http_post_form(url, params)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    req.set_form_data(params)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    JSON.parse(res.body)
  end
end
