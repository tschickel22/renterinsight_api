# frozen_string_literal: true

module Oauth
  # A validated /oauth/authorize request, carried to the React consent page as
  # a signed, ten minute token and back to the API when the user decides.
  #
  # Signing keeps the browser from editing what was asked for (a client could
  # otherwise swap in another redirect or widen the scope between the two
  # screens) without needing a table for requests nobody finishes.
  class AuthorizationRequest
    PURPOSE = :oauth_consent
    TTL = 10.minutes

    # Raised before the redirect URI is trusted: the error is shown to the
    # user and must NOT be sent to the redirect (RFC 6749 section 4.1.2.1).
    class Untrusted < StandardError; end

    # Raised after the redirect URI is trusted: goes back to the app.
    class Redirectable < StandardError
      attr_reader :code, :redirect_uri, :state

      def initialize(code, description, redirect_uri:, state:)
        @code = code
        @redirect_uri = redirect_uri
        @state = state
        super(description)
      end
    end

    attr_reader :client, :redirect_uri, :state, :code_challenge, :scopes, :resource

    def self.from_params(params, request:)
      new(params, request: request).tap(&:validate!)
    end

    def self.verifier
      Rails.application.message_verifier(:oauth_authorization_request)
    end

    def self.from_signed(token)
      data = verifier.verified(token.to_s, purpose: PURPOSE)
      raise Untrusted, 'This sign-in request has expired. Start again from the AI app.' unless data.is_a?(Hash)

      client = OauthClient.find_by(id: data['client_id'])
      raise Untrusted, 'This sign-in request is no longer valid.' unless client

      allocate.tap do |req|
        req.instance_variable_set(:@client, client)
        req.instance_variable_set(:@redirect_uri, data['redirect_uri'])
        req.instance_variable_set(:@state, data['state'])
        req.instance_variable_set(:@code_challenge, data['code_challenge'])
        req.instance_variable_set(:@scopes, data['scopes'])
        req.instance_variable_set(:@resource, data['resource'])
      end
    end

    def initialize(params, request:)
      @params = params
      @request = request
    end

    def validate!
      @client = ClientResolver.find!(@params[:client_id])
      @redirect_uri = resolve_redirect_uri!
      @state = @params[:state].to_s.presence

      unless @params[:response_type] == 'code'
        fail_redirect!('unsupported_response_type', 'Only response_type=code is supported')
      end
      if @params[:code_challenge].blank? || @params[:code_challenge_method] != 'S256'
        fail_redirect!('invalid_request', 'PKCE with code_challenge_method=S256 is required')
      end
      unless @params[:code_challenge].to_s.match?(/\A[A-Za-z0-9\-_]{43,128}\z/)
        fail_redirect!('invalid_request', 'code_challenge is malformed')
      end
      unless Config.resource_matches?(@params[:resource], @request)
        fail_redirect!('invalid_target', 'This authorization server only issues tokens for its own MCP server')
      end

      @code_challenge = @params[:code_challenge].to_s
      @scopes = OauthGrant.normalize_scopes(@params[:scope])
      @resource = Config.resource(@request)
      self
    rescue Error => e
      raise Untrusted, e.message
    end

    def signed
      self.class.verifier.generate(
        { 'client_id' => client.id, 'redirect_uri' => redirect_uri, 'state' => state,
          'code_challenge' => code_challenge, 'scopes' => scopes, 'resource' => resource },
        purpose: PURPOSE, expires_in: TTL
      )
    end

    # The redirect back to the app, always carrying iss (RFC 9207) and state.
    def self.redirect_with(redirect_uri, params)
      uri = URI.parse(redirect_uri)
      query = URI.decode_www_form(uri.query.to_s) + params.compact.map { |k, v| [k.to_s, v.to_s] }
      uri.query = URI.encode_www_form(query)
      uri.to_s
    end

    private

    def resolve_redirect_uri!
      requested = @params[:redirect_uri].to_s.presence
      if requested.nil?
        return client.redirect_uris.first if client.redirect_uris.size == 1

        raise Untrusted, 'redirect_uri is required'
      end
      raise Untrusted, 'redirect_uri is not registered for this app' unless client.redirect_uri_registered?(requested)

      requested
    end

    def fail_redirect!(code, description)
      raise Redirectable.new(code, description, redirect_uri: @redirect_uri, state: @state)
    end
  end
end
