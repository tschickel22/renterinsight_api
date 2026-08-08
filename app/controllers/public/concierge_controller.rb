# frozen_string_literal: true

module Public
  # The chat endpoint behind the concierge widget on a dealer site.
  #
  # Public and unauthenticated, because the people it exists to serve are
  # strangers on a dealer's website. The company's public inventory token is the
  # scope: it names which dealer is being asked, and it is the same token the
  # listing grid on that page already uses, so it grants nothing new.
  class ConciergeController < ActionController::API
    # A model call per request is the expensive path, so this is the one public
    # endpoint worth a cap. Generous enough for a real conversation, mean enough
    # that a script cannot run up a bill.
    RATE_LIMIT = 20
    RATE_WINDOW = 5.minutes
    MAX_MESSAGE = 500

    before_action :set_cors_headers
    before_action :no_store

    def create
      return head :not_found if company.nil?
      # Sold on its own, so a dealer without it must get nothing rather than a
      # degraded version they did not pay for.
      return head :forbidden unless concierge_enabled?
      return too_many if rate_limited?

      result = Concierge::Responder.new(
        website: website,
        message: params[:message].to_s.slice(0, MAX_MESSAGE),
        history: params[:history]
      ).call

      log_usage(result)

      render json: {
        text: result.text,
        actions: result.actions || [],
        listings: result.listings || [],
        # Exposed so the ratio of rules to model answers is measurable rather
        # than assumed. It is the number that tells us whether the cheap tiers
        # are actually carrying the traffic.
        source: result.source
      }
    end

    def options
      head :no_content
    end

    private

    def company
      @company ||= Company.find_by(public_inventory_token: params[:token]) if params[:token].present?
    end

    # The site the visitor is actually on.
    #
    # The token is company-scoped and a company can have several sites, so
    # picking one by heuristic answers as the wrong dealer. Measured in a browser
    # on Mobile Home Masters: the widget greeted the visitor as "Manufactured
    # Home Elite Site 1", a different site of the same company, and would have
    # answered from that site's pages and facts.
    #
    # Scoped through the company either way, so an id in the request body cannot
    # reach another tenant's site.
    def website
      @website ||= begin
        requested = company&.websites&.find_by(id: params[:website_id]) if params[:website_id].present?
        requested || company&.websites&.sites&.where(is_deleted: [false, nil])
                             &.order(Arel.sql("CASE WHEN status = 1 THEN 0 ELSE 1 END"), :id)&.first
      end
    end

    def concierge_enabled?
      ModuleAccessService.new(company).module_enabled?('marketing.ai_concierge')
    rescue StandardError
      false
    end

    # Per token and per address, so one abusive visitor cannot mute the widget
    # for a dealer's real customers.
    def rate_limited?
      key = "concierge:#{params[:token]}:#{request.remote_ip}"
      count = Rails.cache.increment(key, 1, expires_in: RATE_WINDOW)
      # Some cache stores return nil on a first increment rather than 1.
      count.nil? ? Rails.cache.write(key, 1, expires_in: RATE_WINDOW) && false : count > RATE_LIMIT
    rescue StandardError
      false
    end

    def too_many
      render json: { text: 'Give me a moment to catch up, then try again.', actions: [], listings: [] },
             status: :too_many_requests
    end

    # Only the escalations cost anything, so only they are worth a row.
    def log_usage(result)
      return if result.usage.blank?

      AiQueryLog.create!(
        company_id: company.id,
        feature: 'concierge',
        module_key: 'marketing.ai_concierge',
        input_tokens: result.usage[:input_tokens],
        output_tokens: result.usage[:output_tokens],
        execution_status: 'success'
      )
    rescue StandardError => e
      Rails.logger.warn("[Concierge] usage log failed: #{e.message}")
    end

    def set_cors_headers
      headers['Access-Control-Allow-Origin'] = '*'
      headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
      headers['Access-Control-Allow-Headers'] = 'Content-Type'
    end

    def no_store
      headers['Cache-Control'] = 'no-store'
    end
  end
end
