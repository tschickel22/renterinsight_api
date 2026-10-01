# frozen_string_literal: true

module Oauth
  # Where the authorization server and the MCP server say they live.
  #
  # The issuer and resource are compared by exact string match on the client
  # side (RFC 9207, RFC 8707), so they must not drift with whichever hostname a
  # request happened to arrive on. Production sets MCP_PUBLIC_BASE_URL; without
  # it the API's own URL is used, and only tests fall back to the request.
  module Config
    module_function

    def base_url(request = nil)
      configured = ENV['MCP_PUBLIC_BASE_URL'].presence || ENV['RAILS_API_URL'].presence
      return configured.chomp('/') if configured

      request ? request.base_url : 'https://localhost:3001'
    end

    def issuer(request = nil)
      base_url(request)
    end

    def resource(request = nil)
      "#{base_url(request)}/mcp"
    end

    def resource_metadata_url(request = nil)
      "#{base_url(request)}/.well-known/oauth-protected-resource"
    end

    # The React consent page. The browser carries the user's normal session
    # there, through login and MFA if needed.
    def consent_url(signed_request)
      "#{Brand.app_url.to_s.chomp('/')}/oauth/consent?request=#{CGI.escape(signed_request)}"
    end

    # RFC 8707 section 2: compare without a trailing slash and with the scheme
    # and host lowercased. Anything else (another server's URL, a different
    # path) is a token for somebody else.
    def resource_matches?(candidate, request = nil)
      return true if candidate.blank?

      normalize(candidate) == normalize(resource(request))
    end

    def normalize(uri)
      parsed = URI.parse(uri.to_s)
      return nil unless parsed.scheme && parsed.host

      port = parsed.port && parsed.port != parsed.default_port ? ":#{parsed.port}" : ''
      "#{parsed.scheme.downcase}://#{parsed.host.downcase}#{port}#{parsed.path.to_s.chomp('/')}"
    rescue URI::InvalidURIError
      nil
    end
  end
end
