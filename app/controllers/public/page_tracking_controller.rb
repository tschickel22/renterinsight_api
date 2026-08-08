# frozen_string_literal: true

module Public
  # The landing page tracking beacon.
  #
  # Public and unauthenticated by necessity — it is called by a visitor's
  # browser on a dealer's own hostname. It exists as a separate endpoint rather
  # than counting page requests because Public::SitesController serves published
  # pages through a 5-minute edge cache with stale-while-revalidate: most views
  # never reach Rails, so origin-side counting undercounts by whatever
  # Cloudflare's hit rate is, worst on the busiest pages.
  #
  # Its path prefix is in Constraints::TenantWebsiteHost::RESERVED_PREFIXES so a
  # dealer hostname's catch-all does not swallow it.
  class PageTrackingController < ActionController::API
    # Beacons arrive cross-origin from whatever hostname the page is served on,
    # including custom dealer domains, so there is no origin list to check
    # against. The endpoint is write-only, returns nothing about anyone, and
    # takes no credentials — there is nothing for CSRF to protect.
    before_action :set_cors_headers
    before_action :no_store

    def create
      return head :not_found if page.nil?

      Marketing::TrackPageVisit.new(page: page, params: beacon_params, request: request).call
      head :no_content
    rescue Marketing::TrackPageVisit::TrackingError
      # A malformed beacon must never surface to a visitor, and there is no
      # useful client-side recovery. Swallow it as a bad request.
      head :bad_request
    rescue StandardError => e
      # Tracking must never break the page it is measuring.
      Rails.logger.warn("[PageTracking] #{e.class}: #{e.message}")
      head :no_content
    end

    # Browsers preflight the beacon when it carries a JSON content type.
    def options
      head :no_content
    end

    private

    # Any live page, not only landing pages.
    #
    # This was scoped to landing_pages, which is why page_visits was empty: a
    # dealer's ordinary site pages were rejected by the beacon, so a website
    # produced no visits, no sources and no conversions, and the analytics built
    # on top of it had nothing to read. Measured before the change: zero rows in
    # page_visits, ever.
    #
    # A landing page and an inventory page raise the same questions (where did
    # this person come from, what did they look at, did they become a lead), and
    # they are answered by the same records.
    def page
      @page ||= WebsitePage.active.find_by(id: params[:page_id])
    end

    def beacon_params
      params.permit(
        :visitor_token, :session_token, :referrer, :campaign_token,
        :utm_source, :utm_medium, :utm_campaign, :utm_content, :utm_term,
        :max_scroll_depth, :duration_ms,
        events: [:type, :at, { payload: {} }]
      )
    end

    def set_cors_headers
      headers['Access-Control-Allow-Origin'] = '*'
      headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
      headers['Access-Control-Allow-Headers'] = 'Content-Type'
      headers['Access-Control-Max-Age'] = '86400'
    end

    # The one path on a landing page's host that must never be cached. Without
    # this an edge cache could absorb every beacon after the first and report a
    # single visitor for the whole day.
    def no_store
      headers['Cache-Control'] = 'no-store, no-cache, must-revalidate'
    end
  end
end
