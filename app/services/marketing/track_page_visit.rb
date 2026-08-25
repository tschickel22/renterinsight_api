# frozen_string_literal: true

module Marketing
  # Records a beacon payload from a landing page.
  #
  # Deliberately synchronous and cheap: one upsert plus a batch insert of
  # events, no background job. Prod and staging run solid_queue, which is
  # Postgres-backed — a job per beacon would put beacon volume AND job rows on
  # the same database. The client batches events and flushes on an interval and
  # on visibilitychange, so this runs a few times per visit, not per scroll
  # frame.
  class TrackPageVisit
    class TrackingError < StandardError; end

    # A visit older than this is a new session even from the same browser.
    SESSION_WINDOW = 30.minutes

    # Obvious crawlers. Not exhaustive on purpose — this catches the ones that
    # execute JavaScript and would otherwise inflate a dealer's numbers on day
    # one. Flagged, not dropped, so the filtering stays visible.
    BOT_PATTERN = /bot|crawl|spider|slurp|headless|lighthouse|preview|monitor|pingdom|gtmetrix/i

    def initialize(page:, params:, request: nil)
      @page = page
      @params = params
      @request = request
    end

    def call
      raise TrackingError, 'visitor_token and session_token are required' if tokens_missing?

      visit = find_or_create_visit
      apply_progress(visit)
      insert_events(visit)
      visit
    end

    private

    def tokens_missing?
      @params[:visitor_token].blank? || @params[:session_token].blank?
    end

    def find_or_create_visit
      existing = PageVisit.find_by(session_token: @params[:session_token], website_page_id: @page.id)
      return existing if existing

      PageVisit.create!(new_visit_attributes)
    rescue ActiveRecord::RecordNotUnique
      # Two beacons from the same session can race — the first event batch and
      # a fast scroll milestone arrive together. The unique index is what makes
      # that safe; this just re-reads the winner.
      PageVisit.find_by!(session_token: @params[:session_token], website_page_id: @page.id)
    end

    def new_visit_attributes
      now = Time.current
      attrs = {
        company_id: @page.website.company_id,
        website_page_id: @page.id,
        visitor_token: @params[:visitor_token].to_s.first(64),
        session_token: @params[:session_token].to_s.first(64),
        referrer: @params[:referrer].to_s.presence&.first(500),
        utm_source: @params[:utm_source].to_s.presence&.first(120),
        utm_medium: @params[:utm_medium].to_s.presence&.first(120),
        utm_campaign: @params[:utm_campaign].to_s.presence&.first(120),
        utm_content: @params[:utm_content].to_s.presence&.first(120),
        utm_term: @params[:utm_term].to_s.presence&.first(120),
        device_type: device_type,
        country: country,
        region: region,
        ip_hash: ip_hash,
        is_bot: bot?,
        first_seen_at: now,
        last_seen_at: now
      }

      attrs.merge(attribution)
    end

    # A visitor arriving from a campaign email is already resolvable: the link
    # token identifies the enrollment, and the enrollment's recipient is a
    # Lead / Contact / Account. That is the whole of "arrives known" — no
    # fingerprinting, no guessing.
    def attribution
      token = @params[:campaign_token].presence
      return { campaign_id: @page.campaign_id } if token.blank?

      link = CampaignLinkToken.find_by(token: token)
      return { campaign_id: @page.campaign_id } if link.nil?

      enrollment = link.try(:campaign_send)&.campaign_enrollment
      recipient = enrollment&.recipient

      {
        campaign_id: link.campaign_id || @page.campaign_id,
        campaign_enrollment_id: enrollment&.id,
        identified_entity_type: recipient&.class&.name,
        identified_entity_id: recipient&.id,
        identified_at: (Time.current if recipient)
      }.compact
    rescue StandardError => e
      Rails.logger.warn("[TrackPageVisit] campaign attribution failed: #{e.message}")
      { campaign_id: @page.campaign_id }
    end

    def apply_progress(visit)
      updates = { last_seen_at: Time.current }

      depth = @params[:max_scroll_depth].to_i
      updates[:max_scroll_depth] = depth if depth > visit.max_scroll_depth

      duration = @params[:duration_ms].to_i
      updates[:duration_ms] = duration if duration > visit.duration_ms

      updates[:converted] = true if event_types.include?('form_submit')

      visit.update_columns(updates.merge(updated_at: Time.current))
    end

    def event_types
      @event_types ||= Array(@params[:events]).filter_map { |e| e[:type] || e['type'] }
    end

    # insert_all, not create!: a flush carries the whole batch since the last
    # one, and a row-at-a-time insert would be a round trip per scroll
    # milestone. Unknown types are dropped rather than failing the batch —
    # a future client sending an event this server does not know about should
    # not cost the events it does.
    def insert_events(visit)
      rows = Array(@params[:events]).filter_map do |event|
        type = (event[:type] || event['type']).to_s
        next unless PageVisitEvent::EVENT_TYPES.include?(type)

        {
          page_visit_id: visit.id,
          event_type: type,
          occurred_at: parse_time(event[:at] || event['at']),
          payload: (event[:payload] || event['payload'] || {}).to_h,
          created_at: Time.current,
          updated_at: Time.current
        }
      end

      PageVisitEvent.insert_all(rows) if rows.any?
      rows.size
    end

    def parse_time(value)
      return Time.current if value.blank?

      Time.zone.at(value.to_i / 1000.0)
    rescue StandardError
      Time.current
    end

    def user_agent
      @user_agent ||= @request&.user_agent.to_s
    end

    # Where the visitor is, without keeping anything that locates them.
    #
    # Cloudflare proxies every tenant hostname and attaches this to the request,
    # free, on any plan. The column has existed since page_visits was created
    # and nothing has ever written it, because the beacon posted straight to the
    # API host and skipped the proxy entirely.
    #
    # Country only, deliberately. It answers "is this audience in the right
    # state" without retaining anything that identifies a person, which is the
    # same trade ip_hash already makes.
    def country
      code = @request&.headers&.[]('CF-IPCountry').presence
      return nil if code.blank?
      # Cloudflare sends XX when it cannot tell and T1 for Tor. Neither is a
      # place, and storing them would put two fake countries in every report.
      return nil if %w[XX T1].include?(code)

      code.to_s.upcase.first(2)
    end

    # The visitor's state, forwarded by the tenant host Worker.
    #
    # Cloudflare exposes this on request.cf, which is a Worker-runtime object
    # and never a header, so unlike CF-IPCountry it does not arrive on its own —
    # the Worker has to put it on the request. Free on every plan; the paid
    # alternative is a managed transform this zone does not have.
    #
    # Only meaningful for the country it belongs to: several countries use the
    # same two-letter subdivision codes, so a bare "CO" is Colorado or Cordoba
    # depending. Recorded anyway rather than composed, because every reader here
    # groups by country first.
    def region
      code = @request&.headers&.[]('X-DT-Region').presence
      return nil if code.blank?

      code.to_s.upcase.first(8)
    end

    def bot?
      BOT_PATTERN.match?(user_agent)
    end

    def device_type
      return nil if user_agent.blank?
      return 'tablet' if /ipad|tablet/i.match?(user_agent)
      return 'mobile' if /mobile|iphone|android/i.match?(user_agent)

      'desktop'
    end

    # Hashed with a per-installation secret so the digest is not reversible by
    # rainbow table. Nothing here needs the address itself — only to tell two
    # visitors apart.
    def ip_hash
      ip = @request&.remote_ip
      return nil if ip.blank?

      OpenSSL::HMAC.hexdigest('SHA256', hash_secret, ip)
    end

    def hash_secret
      Rails.application.secret_key_base.to_s.first(32)
    end
  end
end
