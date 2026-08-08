# frozen_string_literal: true

module Public
  # The beacon behind a shared demo link.
  #
  # Public and unauthenticated by necessity: the whole point of the link is that
  # a prospect can open it without an account. The token in the URL is the
  # authorisation, and it is the same token that authorises seeing the demo at
  # all, so this exposes nothing the viewer cannot already reach.
  #
  # Client-side rather than counted at the origin, for the same reason the dealer
  # site's beacon is: the preview payload is cached, so most views would never
  # reach Rails and the count would quietly undercount by the cache hit rate.
  class DemoTrackingController < ActionController::API
    before_action :set_cors_headers
    before_action :no_store

    def create
      profile = SiteContentProfile.find_by(preview_token: params[:token])
      # 404 rather than an error: an expired or rotated link is a normal thing
      # for a beacon to hit, and it must not surface to whoever is looking.
      return head :not_found if profile.nil? || !profile.shareable?

      SiteProfileView.record!(
        profile: profile,
        session_token: params[:session_token],
        visitor_token: params[:visitor_token],
        template_id: params[:template_id],
        attributes: {
          referrer: params[:referrer].presence&.slice(0, 500),
          device_type: device_type,
          ip_hash: ip_hash,
          is_internal: ActiveModel::Type::Boolean.new.cast(params[:internal])
        }
      )

      head :no_content
    rescue StandardError => e
      # Tracking must never break the thing it is measuring, least of all in
      # front of a prospect.
      Rails.logger.warn("[DemoTracking] #{e.class}: #{e.message}")
      head :no_content
    end

    def options
      head :no_content
    end

    private

    def set_cors_headers
      headers['Access-Control-Allow-Origin'] = '*'
      headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
      headers['Access-Control-Allow-Headers'] = 'Content-Type'
    end

    def no_store
      headers['Cache-Control'] = 'no-store'
    end

    def device_type
      agent = request.user_agent.to_s
      return 'mobile' if agent.match?(/Mobi|Android|iPhone/i)
      return 'tablet' if agent.match?(/iPad|Tablet/i)

      'desktop'
    end

    # Hashed with a secret so the table cannot be walked back to addresses, and
    # per profile so the same person viewing two demos is not correlatable.
    def ip_hash
      ip = request.remote_ip.presence
      return nil if ip.blank?

      Digest::SHA256.hexdigest("#{ip}:#{params[:token]}:#{hash_secret}")[0, 32]
    end

    def hash_secret
      Rails.application.secret_key_base.to_s[0, 32]
    end
  end
end
