# frozen_string_literal: true

module ApiKeyAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_api_key
    before_action :enforce_rate_limit
  end

  RATE_LIMIT_WINDOW = 1.hour

  private

  # Wraps the whole request, including rescue_from handlers and before_actions
  # that halt, so every call is logged with the status the caller actually got.
  def process_action(*)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    super
  ensure
    log_api_request(started)
  end

  def log_api_request(started)
    ApiRequestLog.insert({
      api_key_id: @current_api_key&.id,
      company_id: @current_company&.id,
      http_method: request.request_method,
      path: request.path.to_s[0, 255],
      status: response.status,
      duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      ip_address: request.remote_ip,
      user_agent: request.user_agent.to_s[0, 255].presence,
      created_at: Time.current
    })
  rescue StandardError => e
    # Logging must never take down the request it is logging.
    Rails.logger.error("[ApiKeyAuthentication] request log failed: #{e.class}: #{e.message}")
  end

  def authenticate_api_key
    token = extract_bearer_token
    unless token
      render json: { error: "Missing API key. Use Authorization: Bearer <api_key>" }, status: :unauthorized
      return
    end

    @current_api_key = ApiKey.find_active_by_token(token)
    unless @current_api_key
      render json: { error: "Invalid or revoked API key" }, status: :unauthorized
      return
    end

    # Resolve company context
    if @current_api_key.company_scoped?
      # Company-scoped key: company is fixed
      @current_company = @current_api_key.company
    else
      # Platform-level key: require X-Company-ID header to specify target company
      company_id = request.headers["X-Company-ID"]
      if company_id.present?
        @current_company = Company.find_by(id: company_id)
        unless @current_company
          render json: { error: "Invalid company ID in X-Company-ID header" }, status: :bad_request
          return
        end
      else
        # Platform key without company header — only valid for platform-level endpoints
        @current_company = nil
      end
    end

    # A suspended or cancelled company's keys stop working, without touching the
    # keys themselves.
    #
    # The partner API descends from ActionController::API, NOT from
    # ApplicationController, so the before_action that locks staff out of a
    # suspended tenant is not in this chain at all , it is not returning early
    # here, it never runs. Measured on a live suspension: six keys carrying
    # leads read+write stayed fully usable after every human had been locked
    # out, and the partner controllers expose index and show, so that is a route
    # out for the lead database and not merely a route in.
    #
    # Deliberately a status check rather than revoking the keys. Revoking is a
    # second piece of state to remember to undo, and a customer who is
    # reinstated would silently keep a dead Facebook and Google intake until
    # someone noticed. This reverses itself the moment the company is active
    # again, which is the property that matters for a billing hold.
    if @current_company&.access_blocked?
      Rails.logger.warn "🚫 [ApiKeyAuthentication] Company #{@current_company.id} is #{@current_company.status}, refusing key #{@current_api_key.id}"
      render json: {
        error: 'This account is not active. Please contact support.',
        code: 'company_suspended'
      }, status: :forbidden
      return
    end

    @current_api_key.touch_usage!
  end

  def enforce_rate_limit
    return unless @current_api_key

    # Skip rate limiting if not configured (nil or 0)
    limit = @current_api_key.rate_limit.to_i
    return if limit <= 0

    # Counted from the request log, which every instance shares. Rails.cache is
    # per instance in production, so the old cache counter let each instance
    # grant the full limit. Refused requests are excluded so a client that keeps
    # retrying through a 429 recovers once its window drains.
    window = RATE_LIMIT_WINDOW
    count = ApiRequestLog.where(api_key_id: @current_api_key.id, created_at: window.ago..)
                         .where.not(status: 429)
                         .count + 1

    if count > limit
      response.set_header("X-RateLimit-Limit", limit.to_s)
      response.set_header("X-RateLimit-Remaining", "0")
      response.set_header("Retry-After", window.to_i.to_s)
      render json: { error: "Rate limit exceeded. Limit: #{limit} requests per hour." }, status: :too_many_requests
      return
    end

    response.set_header("X-RateLimit-Limit", limit.to_s)
    response.set_header("X-RateLimit-Remaining", [limit - count, 0].max.to_s)
  end

  def current_api_key
    @current_api_key
  end

  def current_company
    return @current_company if defined?(@current_company)
    @current_company = @current_api_key&.company
  end

  def current_company_id
    @current_company&.id
  end

  # Require a company context — for endpoints that need tenant isolation
  def require_company_context!
    unless @current_company
      render json: {
        error: "Company context required. Platform-level keys must provide X-Company-ID header."
      }, status: :bad_request
    end
  end

  # No blank-permissions shortcut: a key with no permissions is refused
  # everything (see ApiKey#has_permission?).
  def authorize_permission!(resource, action)
    unless @current_api_key.has_permission?(resource, action)
      render json: {
        error: "Insufficient permissions",
        required: "#{resource}:#{action}"
      }, status: :forbidden
    end
  end

  def extract_bearer_token
    header = request.headers["Authorization"]
    return nil unless header.present?

    scheme, token = header.split(" ", 2)
    return token if scheme&.casecmp("bearer")&.zero? && token.present?

    nil
  end
end
