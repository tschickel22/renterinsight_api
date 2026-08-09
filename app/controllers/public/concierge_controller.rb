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
      # degraded version they did not pay for. A demo is the exception: it is
      # our sales asset, not a customer's site, and the concierge answering from
      # the prospect's own stock is the point of showing it.
      return head :forbidden unless concierge_enabled? || demo?
      return too_many if rate_limited?

      result = Concierge::Responder.new(
        website: website,
        company: company,
        message: params[:message].to_s.slice(0, MAX_MESSAGE),
        history: params[:history],
        visitor: visitor_details,
        capture_enabled: lead_capture_config[:enabled]
      ).call

      log_usage(result)

      render json: {
        text: result.text,
        actions: result.actions || [],
        listings: result.listings || [],
        # Exposed so the ratio of rules to model answers is measurable rather
        # than assumed. It is the number that tells us whether the cheap tiers
        # are actually carrying the traffic.
        source: result.source,
        # Persistent chips. Booking appears ONLY when a scheduler is actually
        # configured, since a "set a meeting" link that opens a form the visitor
        # has already been offered is noise.
        quick_actions: quick_actions,
        # Tells the widget whether it can finish a callback or contact request
        # in the chat, or has to hand the visitor to the dealer's form.
        lead_capture: lead_capture_config,
        platform_brand: platform_brand
      }
    end

    # POST concierge/:token/lead
    #
    # Creates the lead once the assistant has a name and a way to reach them.
    # Separate from the chat endpoint on purpose: answering a question and
    # taking someone's details are different acts, and only one of them should
    # write to a dealer's CRM.
    def lead
      return head :not_found if company.nil?
      return head :forbidden unless concierge_enabled? || demo?
      return too_many if rate_limited?
      # A demo runs on a prospect's data to show them what it would look like.
      # Writing a real lead into the lot company's CRM from one would put a
      # stranger's details in front of a dealer who never asked for them.
      return render json: { status: 'demo' } if demo?

      result = capture.call(
        visitor: visitor_details,
        intent: params[:intent].to_s.presence || 'contact',
        transcript: transcript_param,
        consented: ActiveModel::Type::Boolean.new.cast(params[:consented]),
        request_context: { ip: request.remote_ip, user_agent: request.user_agent,
                           referrer: request.referrer }
      )

      render json: { status: result.status, message: result.message,
                     form_path: result.form_path }.compact
    end

    def options
      head :no_content
    end

    private

    # Only what the scheduler can use. Deliberately not persisted here: this
    # endpoint answers questions, and creating a lead is a separate, consented
    # act rather than a side effect of typing a name into a chat box.
    def visitor_details
      details = params[:visitor]
      return {} unless details.respond_to?(:permit)

      details.permit(:name, :email, :phone).to_h
    end

    def quick_actions
      # Prefilled the same way the in-answer booking link is. The persistent
      # chip is the one most visitors actually click, so leaving it unprefilled
      # would have meant asking for a name and then wasting it.
      booking = Websites::BookingPrefill.apply(
        Websites::BookingUrl.resolve(company: company, location: website&.location),
        **visitor_details.symbolize_keys.slice(:name, :email, :phone)
      )
      actions = []
      actions << { type: 'link', label: 'Set a meeting', url: booking } if booking.present?
      actions << if lead_capture_config[:enabled]
                   { type: 'capture', label: 'Contact us', intent: 'contact' }
                 else
                   { type: 'form', label: 'Contact us', path: '/contact' }
                 end
      actions
    rescue StandardError
      [{ type: 'form', label: 'Contact us', path: '/contact' }]
    end

    def capture
      @capture ||= Concierge::LeadCapture.new(company: company, website: website)
    end

    # Permitted before it travels, so nothing downstream has to reason about
    # ActionController::Parameters.
    def transcript_param
      Array(params[:history]).filter_map do |turn|
        turn.respond_to?(:permit) ? turn.permit(:role, :content).to_h : turn
      end
    end

    def lead_capture_config
      # A demo must never write into the lot company's CRM, so the chat offers
      # the form there instead of collecting details it would have to discard.
      return { enabled: false, form_path: '/contact' } if demo?

      { enabled: capture.available?, consent_text: capture.consent_text, form_path: '/contact' }
    rescue StandardError
      { enabled: false, form_path: '/contact' }
    end

    def platform_brand
      brand = Brand.current(company: company)
      { name: brand.name, url: brand.website_url, favicon_url: brand.favicon_url }
    rescue StandardError
      {}
    end

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

    # A live demo, proven by its own preview token rather than asserted by the
    # caller. Only a platform admin can create one and the token expires, so this
    # cannot be used to get the module for free.
    def demo?
      token = params[:demo_token].presence
      return false if token.blank?

      profile = SiteContentProfile.find_by(preview_token: token)
      profile.present? && profile.shareable?
    rescue StandardError
      false
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
        feature: demo? ? 'concierge_demo' : 'concierge',
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
