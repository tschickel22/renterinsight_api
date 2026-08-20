# frozen_string_literal: true

module Public
  # Where a page reports that something ran off the right edge of the screen.
  #
  # Mobile layout bugs are invisible from here: the app clips overflow rather
  # than scrolling, so a button pushed past the edge simply cannot be reached
  # and nothing anywhere records that it happened. Finding them has meant
  # someone noticing, screenshotting, and describing the screen. This lets the
  # page say so itself.
  #
  # Same defensive shape as ClientErrorsController, and for the same reasons: a
  # small fixed payload, hard truncation, a per-address cap, nothing echoed
  # back. It writes a log line and nothing else, so there is no table to grow
  # and nothing to clean up when the hunt is over.
  #
  # Deliberately records no text content. Element tags, class names, the route
  # and a pixel count describe a layout bug completely; the words inside the
  # element are customer data and would turn a layout report into a data leak.
  class UiOverflowController < ActionController::API
    MAX_FIELD = 300
    RATE_LIMIT = 60
    RATE_WINDOW = 5.minutes

    before_action :set_cors_headers

    def create
      return head :no_content if rate_limited?

      Rails.logger.warn(
        "[UiOverflow] path=#{clip(params[:path])} " \
        "vw=#{params[:viewport].to_i} " \
        "over=#{params[:over].to_i}px " \
        "el=#{clip(params[:tag])} " \
        "cls=#{clip(params[:cls])} " \
        "ua=#{clip(request.user_agent)}"
      )

      head :no_content
    rescue StandardError => e
      # The reporter must never become the error.
      Rails.logger.warn("[UiOverflow] reporter failed: #{e.class}")
      head :no_content
    end

    def options
      head :no_content
    end

    private

    def clip(value)
      value.to_s.gsub(/\s+/, ' ').strip.slice(0, MAX_FIELD)
    end

    def rate_limited?
      key = "ui_overflow:#{request.remote_ip}"
      count = Rails.cache.increment(key, 1, expires_in: RATE_WINDOW)
      count.present? && count > RATE_LIMIT
    rescue StandardError
      false
    end

    def set_cors_headers
      headers['Access-Control-Allow-Origin'] = '*'
      headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
      headers['Access-Control-Allow-Headers'] = 'Content-Type'
      headers['Cache-Control'] = 'no-store'
    end
  end
end
