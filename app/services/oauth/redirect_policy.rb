# frozen_string_literal: true

module Oauth
  # Which redirect URIs an AI app may register.
  #
  # Registration is open by design (Claude and ChatGPT register themselves), so
  # without a host allowlist anyone could register "DealerTide Assistant" with a
  # redirect to their own site and collect approvals. Only the real AI apps'
  # callback hosts are allowed, plus loopback for desktop and CLI clients
  # (Claude Code, Claude Desktop, the MCP inspector), which RFC 8252 lets use
  # any port. MCP_EXTRA_REDIRECT_HOSTS adds more without a deploy.
  module RedirectPolicy
    # Exact callback paths, not whole hosts: chatgpt.com also serves OAuth
    # callbacks for anyone's Custom GPT, so "any path on chatgpt.com" would let
    # a stranger's GPT register as "ChatGPT" and collect a real grant. A path
    # ending in "/" is a prefix, for the per-connector callback ids.
    KNOWN_CALLBACKS = {
      'claude.ai' => ['/api/mcp/auth_callback'],
      'claude.com' => ['/api/mcp/auth_callback'],
      'chatgpt.com' => ['/connector_platform_oauth_redirect', '/connector/oauth/']
    }.freeze
    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1]].freeze

    module_function

    # MCP_EXTRA_REDIRECT_HOSTS: comma separated hosts allowed on any path, for
    # a client we have not pinned yet. Set it knowingly.
    def extra_hosts
      ENV['MCP_EXTRA_REDIRECT_HOSTS'].to_s.split(',').map { |h| h.strip.downcase }.reject(&:blank?)
    end

    # Hosts whose Client ID Metadata Documents we will fetch.
    def allowed_host?(host)
      (KNOWN_CALLBACKS.keys + extra_hosts).include?(host.to_s.downcase)
    end

    def parse(uri)
      parsed = URI.parse(uri.to_s)
      parsed.scheme && parsed.host ? parsed : nil
    rescue URI::InvalidURIError
      nil
    end

    def loopback?(parsed)
      parsed.scheme == 'http' && LOOPBACK_HOSTS.include?(parsed.host.downcase)
    end

    def allowed?(uri)
      parsed = parse(uri)
      return false unless parsed
      return false if parsed.fragment.present? || parsed.userinfo.present?
      return true if loopback?(parsed)
      return false unless parsed.scheme == 'https'

      host = parsed.host.downcase
      return true if extra_hosts.include?(host)

      Array(KNOWN_CALLBACKS[host]).any? do |path|
        path.end_with?('/') ? parsed.path.start_with?(path) && parsed.path.length > path.length : parsed.path == path
      end
    end
  end
end
