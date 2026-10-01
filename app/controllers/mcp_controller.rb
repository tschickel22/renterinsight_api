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
  MAX_BODY_BYTES = 256.kilobytes

  READ_TOOLS = [
    McpTools::Search, McpTools::Fetch, McpTools::GetReferenceData, McpTools::PipelineSummary,
    McpTools::ListLeads, McpTools::ListContacts, McpTools::ListAccounts, McpTools::ListDeals,
    McpTools::ListInventory, McpTools::ListServiceTickets, McpTools::ListQuotes, McpTools::ListMyTasks,
    McpTools::ListCampaigns, McpTools::GetCampaign, McpTools::ListWorkflows, McpTools::GetWorkflow,
    McpTools::ListNurtureSequences
  ].freeze

  PROMPTS = [
    McpPrompts::MorningBriefing, McpPrompts::LeadTriage, McpPrompts::AgingInventory,
    McpPrompts::StalledDeals, McpPrompts::CustomerFollowUp, McpPrompts::ServiceBacklog
  ].freeze

  WRITE_TOOLS = [
    McpTools::CreateLead, McpTools::AddNote, McpTools::CreateTask, McpTools::UpdateLeadStatus,
    McpTools::AssignLead, McpTools::UpdateDealStage, McpTools::CreateServiceTicket,
    McpTools::EnrollInNurture, McpTools::CreateWorkflowDraft, McpTools::UpdateWorkflowDraft,
    McpTools::CreateCampaignDraft
  ].freeze

  def create
    grant, access = authenticate!
    return unless grant

    # JSON-RPC batches were removed from MCP in 2025-06-18. Allowing them would
    # let one POST run thousands of tool calls past the hourly limit below.
    if request.raw_post.bytesize > MAX_BODY_BYTES
      return render json: jsonrpc_error('Request too large.'), status: :payload_too_large
    end
    if request.raw_post.lstrip.start_with?('[')
      return render json: { jsonrpc: '2.0', id: nil, error: { code: -32_600, message: 'Batch requests are not supported.' } },
                    status: :bad_request
    end

    if McpToolCall.where(oauth_grant_id: grant.id, created_at: 1.hour.ago..).count >= CALLS_PER_HOUR
      response.set_header('Retry-After', '600')
      return render json: jsonrpc_error('Too many requests from this connection. Try again in a few minutes.'),
                    status: :too_many_requests
    end

    # Writing needs the token's scope AND, today, ai_connector:update on the
    # person's role, so taking Update off a role makes their app read only
    # without disconnecting it.
    scopes = access.scope_list & grant.scope_list
    scopes -= ['mcp:write'] unless Oauth::AccessPolicy.changes_permitted?(grant.user, grant.company)
    ctx = McpTools::Context.new(user: grant.user, company: grant.company, grant: grant,
                                scopes: scopes, ip_address: request.remote_ip)
    result = build_server(ctx).handle_json(request.raw_post)

    # A notification (no id) has nothing to answer.
    return head :accepted if result.nil?

    render json: result
  end

  def method_not_allowed
    response.set_header('Allow', 'POST')
    head :method_not_allowed
  end

  private

  def build_server(ctx)
    tools = ctx.write_allowed? ? READ_TOOLS + WRITE_TOOLS : READ_TOOLS
    brand = Brand.current(company: ctx.company)

    MCP::Server.new(
      name: brand.short_name.to_s.parameterize.presence || 'dms',
      title: brand.name,
      version: '1.0.0',
      website_url: brand.website_url,
      instructions: instructions(ctx, brand),
      tools: tools,
      prompts: PROMPTS,
      server_context: ctx,
      configuration: MCP::Configuration.new(
        validate_tool_call_arguments: true,
        exception_reporter: lambda { |error, _context|
          Rails.logger.error("[MCP] #{error.class}: #{error.message}\n#{Array(error.backtrace).first(8).join("\n")}")
        }
      )
    )
  end

  # Said in so many words because an AI on a read-only connection otherwise
  # concludes the server cannot write at all and tells the user so.
  READ_ONLY_NOTE = 'This connection is read only, so the tools that add notes, tasks and leads or change ' \
                   'statuses and deal stages are hidden. If the user wants those, tell them to disconnect ' \
                   'and reconnect this connector and tick "Also let it make changes" on the sign-in screen. ' \
                   'Their role also needs AI Connector Update, which an admin sets under Users, Roles & Permissions.'

  def instructions(ctx, brand)
    <<~TEXT.squish
      You are connected to #{brand.name}, a dealer management system, as #{ctx.user.full_name}
      at #{ctx.company.name}. Every tool runs with this person's own permissions and locations.
      Record ids are typed, like lead:42, deal:7 or unit:118; search and the list tools return
      them and fetch reads one. Call get_reference_data before filtering by a status or stage
      or assigning work to someone.
      #{ctx.write_allowed? ? 'Before any tool that changes data, confirm the change with the user.' : READ_ONLY_NOTE}
      #{boundaries(brand, ctx)}
    TEXT
  end

  # What the connector deliberately does not do, and what to tell the user
  # instead. Without this an AI either claims it cannot help at all or invents
  # a workaround; with it, it says what it did and where the person finishes.
  def boundaries(brand, ctx)
    app = brand.name
    cost_answer =
      if ctx.show_costs?
        'Cost and gross figures appear under "costs" on deals and inventory when this person can see them in ' \
          "#{app}; commission is never available here. Treat cost as internal: never put it in anything written " \
          'for a customer.'
      else
        "Dealer cost, gross, margin or commission: \"Those figures are not available through this connector; " \
          "your #{app} admin can allow it under Settings, AI Apps.\""
      end
    <<~TEXT.squish
      Some things are deliberately not possible through this connector. When the user asks for one,
      say plainly that you cannot do it here and tell them where to do it, using these answers:
      Activating, pausing or deleting a workflow: "I can build it as a draft, but it has to be
      activated in #{app}: open the link, review the steps and click Activate." Starting, scheduling,
      sending or test sending a campaign: "I can draft the campaign, but sending is done in #{app}:
      open it, check the audience and sender, then click Start." Sending an email or text directly:
      "I cannot send messages, but I can draft it for you to send, add someone to an existing nurture
      sequence, or draft a campaign." Deleting any record: "I cannot delete records; that is done in
      #{app}." Changing many records at once (more than a handful): "I make changes one record at a time
      and there is a limit per hour; for bulk changes use the bulk actions in #{app}." #{cost_answer} Users,
      roles, permissions, company settings, invoices, payments and loans: "That is not available here;
      use #{app}." If a tool refuses something, repeat its reason to the user rather than guessing.
      Write customer-facing copy plainly and never use em dashes or en dashes.
    TEXT
  end

  # Returns [grant, access token], or renders 401 with the challenge MCP
  # clients follow to find the authorization server.
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
      # A revoked connection is a dead token: sign in again. Anything else
      # (role, add-on, suspended account, inactive user) is a permission the
      # person does not have right now, and signing in again cannot fix it.
      # 401 there made Claude report "Authentication failed" and loop through
      # sign-in; 403 with the reason in the body lets it say what is wrong.
      return grant.active? ? forbidden(reason) : challenge(reason)
    end

    [grant, access]
  end

  # Both scopes, so Claude and ChatGPT ask for both and the consent screen can
  # offer "allow changes". Advertising read alone (as before) meant the apps
  # never requested write, so a user could never turn it on. The consent
  # screen and the role's AI Connector Update permission still decide.
  def advertised_scope
    OauthGrant::SCOPES.join(' ')
  end

  def challenge(description)
    parts = ["Bearer resource_metadata=\"#{Oauth::Config.resource_metadata_url(request)}\"",
             "scope=\"#{advertised_scope}\""]
    parts << "error=\"invalid_token\", error_description=\"#{description.delete('"')}\"" if description
    response.set_header('WWW-Authenticate', parts.join(', '))
    render json: { error: 'unauthorized', error_description: description || 'Sign in to connect.' }, status: :unauthorized
    nil
  end

  def forbidden(reason)
    response.set_header('WWW-Authenticate',
                        "Bearer error=\"insufficient_scope\", error_description=\"#{reason.delete('"')}\", " \
                        "resource_metadata=\"#{Oauth::Config.resource_metadata_url(request)}\"")
    render json: jsonrpc_error(reason), status: :forbidden
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
