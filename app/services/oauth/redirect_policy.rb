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
    DEFAULT_HOSTS = %w[claude.ai claude.com chatgpt.com platform.openai.com].freeze
    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1]].freeze

    module_function

    def allowed_hosts
      DEFAULT_HOSTS + ENV['MCP_EXTRA_REDIRECT_HOSTS'].to_s.split(',').map { |h| h.strip.downcase }.reject(&:blank?)
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

    def allowed_host?(host)
      allowed_hosts.include?(host.to_s.downcase)
    end

    def allowed?(uri)
      parsed = parse(uri)
      return false unless parsed
      return false if parsed.fragment.present? || parsed.userinfo.present?
      return true if loopback?(parsed)

      parsed.scheme == 'https' && allowed_host?(parsed.host)
    end
  end
end
