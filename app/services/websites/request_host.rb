# frozen_string_literal: true

module Websites
  # The hostname a visitor actually asked for.
  #
  # Normally that is request.host. But dealer sites arrive through a Cloudflare Worker that
  # rewrites Host to the Render service's own hostname, because Render rejects any Host it
  # does not recognise as a registered domain (measured: a foreign Host returns 403 while
  # the service's own returns 200). The Worker preserves the real hostname in a header.
  #
  # That header is only trusted when accompanied by a shared secret. Without that check,
  # anyone could hit the Render hostname directly, claim to be any dealer's domain, and be
  # served that dealer's site under it.
  module RequestHost
    TENANT_HOST_HEADER = 'HTTP_X_TENANT_HOST'
    PROXY_SECRET_HEADER = 'HTTP_X_TENANT_PROXY_SECRET'

    module_function

    def for(request)
      forwarded = forwarded_host(request)
      return forwarded if forwarded.present?

      request.host.to_s.downcase
    end

    def forwarded_host(request)
      secret = ENV['TENANT_PROXY_SECRET'].presence
      return nil if secret.blank?

      provided = request.get_header(PROXY_SECRET_HEADER).to_s
      return nil if provided.blank?
      # Constant time: this decides whose site gets served.
      return nil unless ActiveSupport::SecurityUtils.secure_compare(secret, provided)

      host = request.get_header(TENANT_HOST_HEADER).to_s.downcase.strip.split(':').first
      host.presence
    end
  end
end
