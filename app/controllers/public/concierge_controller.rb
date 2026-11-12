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
      return head :forbidden unless embed_allowed?
      return too_many if rate_limited?
      # A live site's chat is Quinn's, kept in the Inbox (E96, 2026-11-07). A
      # demo keeps the answer-only concierge: it writes nothing anywhere.
      return quinn_create unless demo?

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

    # GET concierge/:token/chat?chat_key=&after=
    #
    # New messages for the visitor's widget, asked every few seconds while it
    # is open: Quinn's and, once a person has the chat, the rep's from the
    # Inbox. Asking is also how the Inbox knows the visitor is still there.
    def chat
      return head :not_found if company.nil?
      return head :forbidden unless concierge_enabled? && embed_allowed?

      conversation = Assistant::WebChat.find(company, params[:chat_key])
      return render(json: { messages: [], closed: true }) unless conversation

      Assistant::WebChat.new(conversation).seen!
      after = params[:after].to_i
      messages = conversation.chat_messages.where('id > ?', after).order(:id).limit(50).map(&:as_chat_json)
      render json: { messages: messages, person: conversation.handed_off?, closed: conversation.status == 'closed' }
    end

    # GET concierge/:token/config?site=
    #
    # What the embedded chat needs before the first message: the name, colour
    # and greeting. Only for a page on a site the dealer listed.
    def chat_config
      return head :not_found if company.nil?
      return head :forbidden unless concierge_enabled? && embed_allowed?

      settings = Assistant::Settings.for(company)
      render json: {
        dealer_name: company.name, assistant_name: settings.assistant_name,
        color: params[:color].to_s.match?(/\A#[0-9a-f]{6}\z/i) ? params[:color] : chat_color,
        greeting: chat_greeting(settings), placeholder: chat_placeholder,
        quick_actions: quick_actions.reject { |a| a[:type] == 'form' },
        lead_capture: lead_capture_config, platform_brand: platform_brand
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

      # A chat already tied to a lead: the visitor's number and their yes to
      # texts go on that lead rather than making a second one.
      chat_conversation = Assistant::WebChat.find(company, params[:chat_key])
      if chat_conversation&.conversable.is_a?(Lead)
        return render json: { status: 'created', message: add_to_chat_lead(chat_conversation.conversable) }
      end

      result = capture.call(
        visitor: visitor_details,
        intent: params[:intent].to_s.presence || 'contact',
        transcript: transcript_param,
        consented: ActiveModel::Type::Boolean.new.cast(params[:consented]),
        request_context: { ip: request.remote_ip, user_agent: request.user_agent,
                           referrer: request.referrer }
      )

      lead = result.status == 'created' ? company.leads.find_by(id: result.lead_id) : nil
      Assistant::WebChat.link!(chat_conversation, lead) if lead && chat_conversation

      # A lead made here counts on the page's ad pixel. Adding to the chat's
      # own lead (above) does not: that person already counted.
      render json: { status: result.status, message: result.message, form_path: result.form_path,
                     events: lead ? [Assistant::Conversions.lead(lead)] : nil }.compact
    end

    def options
      head :no_content
    end

    private

    def quinn_create
      message = params[:message].to_s.strip.slice(0, MAX_MESSAGE)
      conversation = Assistant::WebChat.find(company, params[:chat_key])
      return render(json: { messages: [], text: nil, actions: [], listings: [] }) if message.blank? && conversation.nil?

      chat_site = embed? ? nil : website
      conversation ||= Assistant::WebChat.start!(company: company, website: chat_site, page_url: page_url)
      reply = Assistant::WebChat.new(conversation, website: chat_site,
                                                   request_context: { ip: request.remote_ip, user_agent: request.user_agent,
                                                                      referrer: request.referrer }).visitor_says!(message)
      # Quinn's model calls log their own usage (Assistant::Brain).

      last = reply.messages.last
      render json: {
        chat_key: conversation.visitor_token, messages: reply.messages, person: conversation.reload.handed_off?,
        ask_consent: reply.ask_consent == true, visitor: reply.visitor || {},
        # The single-answer shape older widgets read.
        text: last&.dig(:content), actions: last ? Array(last[:actions]) : [], listings: last ? last[:listings] : [], source: 'quinn',
        quick_actions: embed? ? quick_actions.reject { |a| a[:type] == 'form' } : quick_actions,
        lead_capture: lead_capture_config, platform_brand: platform_brand,
        # A lead or visit this message made, for the page's ad pixel (Assistant::Conversions).
        events: reply.events || []
      }
    end

    # The embedded chat on a dealer's own site sends the page's address as
    # `site`. It answers only on the sites the dealer listed, so the embed line
    # copied onto someone else's site gets nothing (E96).
    def embed?
      params[:site].present? || params[:embed].present?
    end

    def embed_allowed?
      return true unless embed?

      Assistant::Settings.for(company).chat_site_allowed?(params[:site])
    end

    def page_url
      (params[:page_url].presence || request.referrer).to_s.truncate(500)
    end

    def chat_color
      site = website
      site&.theme.to_h['primary_color'].presence || '#2563eb'
    rescue StandardError
      '#2563eb'
    end

    def add_to_chat_lead(lead)
      phone = visitor_details['phone'].to_s.strip
      consented = ActiveModel::Type::Boolean.new.cast(params[:consented]) == true
      changes = {}
      changes[:phone] = phone if phone.present? && consented && lead.phone.blank?
      if consented && phone.present? && (lead.phone.blank? || Conversation.normalize_phone(lead.phone) == Conversation.normalize_phone(phone))
        changes[:sms_inquiry_consent] = true
        changes[:sms_inquiry_consent_at] = Time.current
      end
      changes[:email] = visitor_details['email'] if visitor_details['email'].present? && lead.email.blank?
      lead.update!(changes) if changes.any?
      "Thanks. Someone from #{company.name} will be in touch shortly."
    rescue StandardError => e
      Rails.logger.warn("[Concierge] could not add to chat lead #{lead&.id}: #{e.message}")
      "Thanks. Someone from #{company.name} will be in touch shortly."
    end

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
      actions << { type: 'link', label: 'Set a meeting', url: booking } if booking.present? && !software?
      actions << if lead_capture_config[:enabled]
                   { type: 'capture', label: 'Contact us', intent: 'contact' }
                 else
                   { type: 'form', label: 'Contact us', path: '/contact' }
                 end
      # Quinn books in the chat itself, so this chip just says so for them and
      # the reply offers times. A demo site keeps the answer-only concierge,
      # which cannot book. A software company books demos, not visits.
      if !demo? && Assistant::Settings.for(company).books_visits? && (software? || booking.blank?)
        actions << if software?
                     { type: 'ask', label: 'Set a demo', message: "I'd like to set up a demo." }
                   else
                     { type: 'ask', label: 'Book a visit', message: "I'd like to book a visit." }
                   end
      end
      actions
    rescue StandardError
      [{ type: 'form', label: 'Contact us', path: '/contact' }]
    end

    def capture
      @capture ||= Concierge::LeadCapture.new(company: company, website: website)
    end

    # A software company (DealerTide itself) sells to dealers: the chat offers a
    # demo and answers about the product, not homes, prices and visits.
    def software?
      return @software if defined?(@software)

      @software = company.present? && Assistant::Software.for?(company)
    end

    def chat_greeting(settings)
      if software?
        "Hi, I'm #{settings.assistant_name} with #{company.name}. Ask me how #{company.name} can help your dealership, or set up a #{settings.visit_minutes} minute demo."
      else
        "Hi, I'm #{settings.assistant_name} with #{company.name}. Ask me about homes, prices or a visit."
      end
    end

    def chat_placeholder
      software? ? 'Ask about our products or a demo…' : 'Ask about homes, financing, a visit…'
    end

    # Permitted before it travels, so nothing downstream has to reason about
    # ActionController::Parameters.
    def transcript_param
      Array(params[:history]).filter_map do |turn|
        turn.respond_to?(:permit) ? turn.permit(:role, :content).to_h : turn
      end
    end

    def lead_capture_config
      # A demo collects in the chat exactly like a live site and then keeps
      # nothing: #lead answers 'demo' rather than writing into the lot
      # company's CRM. Handing the visitor to the contact page instead was the
      # bug behind "request a callback does nothing, it just closes the chat" ,
      # the panel shut, the preview swapped to a page nobody asked for, and the
      # one thing the assistant exists to do never happened in front of the
      # prospect being sold to.
      return { enabled: true, consent_text: capture.consent_text, form_path: '/contact' } if demo?

      { enabled: capture.available?, consent_text: capture.consent_text, form_path: '/contact' }
    rescue StandardError
      { enabled: false, form_path: '/contact' }
    end

    def platform_brand
      brand = Brand.current(company: company)
      { name: brand.name, url: brand.website_url, favicon_url: brand.favicon_url,
        login_url: Brand.login_url(company: company) }
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
      headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
      headers['Access-Control-Allow-Headers'] = 'Content-Type'
    end

    def no_store
      headers['Cache-Control'] = 'no-store'
    end
  end
end
