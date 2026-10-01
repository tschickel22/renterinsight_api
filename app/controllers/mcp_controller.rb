# frozen_string_literal: true

# POST /mcp: the MCP server Claude and ChatGPT talk to (backlog E53).
#
# Stateless Streamable HTTP: every JSON-RPC message gets a plain JSON answer
# in the same response. No SSE stream and no session, so no Puma thread is
# held open between calls, and GET (the optional server-to-client stream) is
# answered 405 as the spec allows.
#
# Auth is an OAuth access token from Oauth::TokensController, bound to one
# user at one company. Bearer header only, never cookies, which is also why
# there is no Origin check: a page in a browser cannot ride a session here.
class McpController < ActionController::API
  CALLS_PER_HOUR = 600

  READ_TOOLS = [
    McpTools::Search, McpTools::Fetch, McpTools::GetReferenceData, McpTools::PipelineSummary,
    McpTools::ListLeads, McpTools::ListContacts, McpTools::ListAccounts, McpTools::ListDeals,
    McpTools::ListInventory, McpTools::ListServiceTickets, McpTools::ListQuotes, McpTools::ListMyTasks
  ].freeze

  WRITE_TOOLS = [
    McpTools::CreateLead, McpTools::AddNote, McpTools::CreateTask, McpTools::UpdateLeadStatus,
    McpTools::AssignLead, McpTools::UpdateDealStage, McpTools::CreateServiceTicket
  ].freeze

  def create
    grant = authenticate!
    return unless grant

    if McpToolCall.where(oauth_grant_id: grant.id, created_at: 1.hour.ago..).count >= CALLS_PER_HOUR
      response.set_header('Retry-After', '600')
      return render json: jsonrpc_error('Too many requests from this connection. Try again in a few minutes.'),
                    status: :too_many_requests
    end

    ctx = McpTools::Context.new(user: grant.user, company: grant.company, grant: grant, ip_address: request.remote_ip)
    result = build_server(ctx, grant).handle_json(request.raw_post)

    # A notification (no id) has nothing to answer.
    return head :accepted if result.nil?

    render json: result
  end

  def method_not_allowed
    response.set_header('Allow', 'POST')
    head :method_not_allowed
  end

  private

  def build_server(ctx, grant)
    tools = grant.write_allowed? ? READ_TOOLS + WRITE_TOOLS : READ_TOOLS
    brand = Brand.current(company: ctx.company)

    MCP::Server.new(
      name: brand.short_name.to_s.parameterize.presence || 'dms',
      title: brand.name,
      version: '1.0.0',
      website_url: brand.website_url,
      instructions: instructions(ctx, brand, grant),
      tools: tools,
      server_context: ctx,
      configuration: MCP::Configuration.new(
        validate_tool_call_arguments: true,
        exception_reporter: lambda { |error, _context|
          Rails.logger.error("[MCP] #{error.class}: #{error.message}\n#{Array(error.backtrace).first(8).join("\n")}")
        }
      )
    )
  end

  def instructions(ctx, brand, grant)
    <<~TEXT.squish
      You are connected to #{brand.name}, a dealer management system, as #{ctx.user.full_name}
      at #{ctx.company.name}. Every tool runs with this person's own permissions and locations.
      Record ids are typed, like lead:42, deal:7 or unit:118; search and the list tools return
      them and fetch reads one. Call get_reference_data before filtering by a status or stage
      or assigning work to someone. Dealer cost and profit figures are never available here.
      #{grant.write_allowed? ? 'Before any tool that changes data, confirm the change with the user.' : 'This connection is read only.'}
    TEXT
  end

  # Returns the grant, or renders 401 with the challenge MCP clients follow to
  # find the authorization server.
  def authenticate!
    header = request.headers['Authorization'].to_s
    scheme, token = header.split(' ', 2)
    return challenge(nil) unless scheme&.casecmp?('bearer') && token.present?

    access = OauthToken.find_by_plaintext(token.strip, kind: 'access')
    return challenge('The access token is invalid or expired.') unless access&.usable?

    grant = access.oauth_grant
    unless Oauth::Config.resource_matches?(grant.resource, request)
      return challenge('The access token was not issued for this server.')
    end
    if (reason = Oauth::AccessPolicy.denial_reason(grant))
      return challenge(reason)
    end

    grant
  end

  def challenge(description)
    parts = ["Bearer resource_metadata=\"#{Oauth::Config.resource_metadata_url(request)}\"",
             "scope=\"#{OauthGrant::SCOPES.first}\""]
    parts << "error=\"invalid_token\", error_description=\"#{description.delete('"')}\"" if description
    response.set_header('WWW-Authenticate', parts.join(', '))
    render json: { error: 'unauthorized', error_description: description || 'Sign in to connect.' }, status: :unauthorized
    nil
  end

  def jsonrpc_error(message)
    id = begin
      JSON.parse(request.raw_post)['id']
    rescue StandardError
      nil
    end
    { jsonrpc: '2.0', id: id, error: { code: -32_000, message: message } }
  end
end
