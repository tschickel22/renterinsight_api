# frozen_string_literal: true

module Oauth
  # Discovery documents. An MCP client finds the protected resource metadata
  # from the 401 on /mcp, reads which authorization server to use, then reads
  # that server's metadata for every endpoint below.
  class MetadataController < BaseController
    # RFC 9728. Served at the root and at the path-suffixed form, since clients
    # try "/.well-known/oauth-protected-resource/mcp" first for a resource
    # with a path.
    def protected_resource
      render json: {
        resource: Config.resource(request),
        authorization_servers: [Config.issuer(request)],
        scopes_supported: OauthGrant::SCOPES,
        bearer_methods_supported: ['header'],
        resource_name: Brand.current.name
      }
    end

    # RFC 8414, also answered at the OpenID discovery path because MCP clients
    # are required to try both.
    def authorization_server
      base = Config.base_url(request)
      render json: {
        issuer: Config.issuer(request),
        authorization_endpoint: "#{base}/oauth/authorize",
        token_endpoint: "#{base}/oauth/token",
        registration_endpoint: "#{base}/oauth/register",
        revocation_endpoint: "#{base}/oauth/revoke",
        response_types_supported: ['code'],
        response_modes_supported: ['query'],
        grant_types_supported: %w[authorization_code refresh_token],
        code_challenge_methods_supported: ['S256'],
        token_endpoint_auth_methods_supported: ['none'],
        revocation_endpoint_auth_methods_supported: ['none'],
        scopes_supported: OauthGrant::SCOPES + ['offline_access'],
        client_id_metadata_document_supported: true,
        authorization_response_iss_parameter_supported: true
      }
    end
  end
end
