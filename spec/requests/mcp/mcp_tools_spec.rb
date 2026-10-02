# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# What an AI app can see and do through /mcp. The rule under test throughout:
# exactly what the signed-in person could see and do in the app, at their one
# company, and never dealer cost.
RSpec.describe 'MCP tools', :mcp, type: :request do
  before { seed_rbac! }

  let(:company) { connector_company }
  let(:denver) { company.locations.create!(name: 'Denver', timezone: 'America/Denver') }
  let(:boulder) { company.locations.create!(name: 'Boulder', timezone: 'America/Denver') }
  let(:full) do
    { 'leads' => %w[read create update], 'crm' => %w[read update], 'deals' => %w[read update],
      'inventory' => %w[read], 'service' => %w[read create], 'finance' => %w[read], 'tasks' => %w[read create] }
  end
  let(:user) { connector_user(company, full) }
  let(:token) { connect!(user)['access_token'] }

  let(:buyer) { company.contacts.create!(first_name: 'Ana', last_name: 'Diaz', location_id: denver.id) }

  def lead!(attrs = {})
    company.leads.create!({ first_name: 'Maria', last_name: 'Lopez', email: "m-#{SecureRandom.hex(3)}@example.com",
                            status: 'new', location_id: denver.id }.merge(attrs))
  end

  describe 'the handshake' do
    it 'initializes and lists the tools' do
      body = mcp_post(token, 'initialize', { protocolVersion: '2025-06-18', capabilities: {},
                                             clientInfo: { name: 'claude-ai', version: '1' } })
      expect(body.dig('result', 'serverInfo', 'title')).to eq(Brand.current.name)
      expect(body.dig('result', 'instructions')).to include(user.full_name)

      names = mcp_post(token, 'tools/list').dig('result', 'tools').map { |t| t['name'] }
      expect(names).to include('search', 'fetch', 'list_leads', 'create_lead', 'update_deal_stage')
    end

    it 'hides the write tools from a read-only connection' do
      read_only = connect!(user, allow_write: false)['access_token']
      tools = mcp_post(read_only, 'tools/list').dig('result', 'tools')

      expect(tools.map { |t| t['name'] }).not_to include('create_lead', 'add_note')
      instructions = mcp_post(read_only, 'initialize', { protocolVersion: '2025-06-18', capabilities: {},
                                                        clientInfo: { name: 'claude-ai', version: '1' } })
                     .dig('result', 'instructions')
      expect(instructions).to include('Also let it make changes')
      expect(tools).to all(include('annotations' => include('readOnlyHint' => true)))
    end

    it 'refuses JSON-RPC batches, which would slip past the hourly call limit' do
      batch = Array.new(3) { |i| { jsonrpc: '2.0', id: i, method: 'tools/call', params: { name: 'get_reference_data', arguments: {} } } }
      post '/mcp', params: batch.to_json,
                   headers: { 'CONTENT_TYPE' => 'application/json', 'Authorization' => "Bearer #{token}" }

      expect(response).to have_http_status(:bad_request)
      expect(McpToolCall.count).to eq(0)
    end

    it 'answers GET with 405, since there is no server stream' do
      get '/mcp', headers: { 'Authorization' => "Bearer #{token}" }
      expect(response).to have_http_status(:method_not_allowed)
    end
  end

  describe 'search and fetch' do
    it 'finds a lead and fetches it with its notes' do
      lead = lead!
      Note.create!(entity_type: 'lead', entity_id: lead.id.to_s, content: 'Wants a 3 bed by spring', user_id: user.id)

      results, = call_tool(token, 'search', query: 'Lopez')
      hit = results['results'].find { |r| r['id'] == "lead:#{lead.id}" }
      expect(hit['url']).to end_with("/crm/leads/#{lead.id}")

      doc, = call_tool(token, 'fetch', id: "lead:#{lead.id}")
      expect(doc['text']).to include('Wants a 3 bed by spring')
    end

    it "cannot reach another company's records" do
      other = connector_company
      foreign = other.leads.create!(first_name: 'Maria', last_name: 'Lopez', email: 'x@example.com', status: 'new')

      results, = call_tool(token, 'search', query: 'Lopez')
      expect(results['results'].map { |r| r['id'] }).not_to include("lead:#{foreign.id}")

      _doc, is_error, text = call_tool(token, 'fetch', id: "lead:#{foreign.id}")
      expect(is_error).to be(true)
      expect(text).to include('No record')
    end
  end

  describe 'permissions and locations' do
    it "refuses a record type the user's role cannot read" do
      leads_only = connect!(connector_user(company, { 'leads' => %w[read] }))['access_token']

      _r, is_error, text = call_tool(leads_only, 'list_deals')
      expect(is_error).to be(true)
      expect(text).to include('does not allow read on deals')
      expect(McpToolCall.last).to have_attributes(tool_name: 'list_deals', status: 'denied')
    end

    it 'shows a location-tier user only their location' do
      mine = lead!(location_id: denver.id)
      theirs = lead!(location_id: boulder.id)
      local = connect!(connector_user(company, { 'leads' => %w[read] }, location: denver))['access_token']

      listed, = call_tool(local, 'list_leads')
      ids = listed['items'].map { |i| i['id'] }
      expect(ids).to include("lead:#{mine.id}")
      expect(ids).not_to include("lead:#{theirs.id}")
    end

    it 'shows a company-wide role the whole company, records with no location included' do
      unlocated = lead!(location_id: nil)
      listed, = call_tool(connect!(connector_user(company, { 'leads' => %w[read] }))['access_token'], 'list_leads')

      expect(listed['items'].map { |i| i['id'] }).to include("lead:#{unlocated.id}")
    end

    it 'shows a non-admin with no locations nothing, rather than the whole company' do
      lead!
      nowhere = company.users.create!(email: "n-#{SecureRandom.hex(3)}@example.com", first_name: 'N', last_name: 'L',
                                      password: 'Pass1234!', role: 'user', status: 'active')
      r = Role.create!(company_id: company.id, key: "loc-#{SecureRandom.hex(2)}", name: 'Loc', tier: 'location', active: true)
      %w[leads ai_connector].each do |key|
        RolePermission.create!(role: r, resource: Resource.find_by!(key: key), action: Action.find_by!(key: 'read'),
                               scope: Scope.find_by!(key: 'all'), granted: true)
      end
      # A location-tier assignment pointing at a location this company does
      # not own (stale data after a move): no usable locations, and the
      # controllers would fall back to the whole company here.
      elsewhere = connector_company.locations.create!(name: 'Elsewhere', timezone: 'America/Denver')
      assignment = nowhere.user_role_assignments.create!(role: r, company_id: company.id, tier: 'location', location_id: boulder.id)
      assignment.update_column(:location_id, elsewhere.id)
      Rails.cache.clear

      listed, = call_tool(connect!(nowhere)['access_token'], 'list_leads')
      expect(listed['items']).to be_empty
    end
  end

  describe 'dealer cost' do
    it 'never appears on a deal or an inventory unit' do
      unit = company.vehicles.create!(stock_number: 'S-100', vin: 'CHAMP123456', year: 2026, make: 'Champion', model: 'Aspire',
                                      status: 'available', sale_price: 120_000, cost: 80_000, location_id: denver.id)
      deal = company.deals.create!(name: 'Lopez home', stage: 'proposal', contact_id: buyer.id, selling_price: 120_000, unit_cost: 80_000,
                                   front_gross: 40_000, commission_amount: 3_000, vehicle_id: unit.id, location_id: denver.id)

      unit_doc, = call_tool(token, 'fetch', id: "unit:#{unit.id}")
      deal_doc, = call_tool(token, 'fetch', id: "deal:#{deal.id}")
      listed, = call_tool(token, 'list_inventory')

      [unit_doc['text'], deal_doc['text'], listed.to_json].each do |text|
        expect(text).not_to match(/cost|gross|margin|commission|holdback|80000|40000/i)
      end
      expect(deal_doc['text']).to include('120000')
    end
  end

  describe 'dealer cost when the dealer allows it' do
    let!(:unit) do
      company.vehicles.create!(stock_number: 'S-200', vin: 'CHAMP999', year: 2026, make: 'Champion', model: 'Vista',
                               status: 'available', sale_price: 120_000, dealer_cost: 80_000, freight_cost: 2_500,
                               location_id: denver.id)
    end
    let!(:deal) do
      company.deals.create!(name: 'Margin deal', stage: 'proposal', contact_id: buyer.id, selling_price: 120_000,
                            unit_cost: 80_000, front_gross: 40_000, commission_amount: 3_000, location_id: denver.id)
    end

    it 'shows deal and inventory cost to someone who sees it in the app, never commission' do
      admin = connector_user(company, {}, role: 'company_admin')
      put '/api/v1/connected-apps/settings', params: { show_costs: true }, headers: app_headers(admin)
      expect(response.parsed_body['show_costs']).to be(true)

      deal_doc, = call_tool(token, 'fetch', id: "deal:#{deal.id}")
      unit_list, = call_tool(token, 'list_inventory')

      expect(deal_doc['text']).to include('"unit_cost": 80000.0', '"front_gross": 40000.0')
      expect(deal_doc['text']).not_to include('commission')
      expect(unit_list['items'].find { |i| i['id'] == "unit:#{unit.id}" }['costs'])
        .to include('dealer_cost' => 80_000.0, 'freight_cost' => 2_500.0)
    end

    it 'tells the AI cost is internal when on, and how to turn it on when off' do
      off = mcp_post(token, 'initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'c', version: '1' } })
      expect(off.dig('result', 'instructions')).to include('your', 'admin can allow it under Settings, Integrations, AI Apps')

      Setting.set('Company', company.id, 'mcp_settings', { 'show_costs' => true })
      on = mcp_post(token, 'initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'c', version: '1' } })
      expect(on.dig('result', 'instructions')).to include('never put it in anything written for a customer')
    end
  end

  describe 'export limits' do
    it 'caps rows per call and stops at the daily record budget' do
      3.times { lead! }
      Setting.set('Company', company.id, 'mcp_settings', { 'daily_record_limit' => 4 })

      first, = call_tool(token, 'list_leads', limit: 2)
      expect(first['count']).to eq(2)
      second, = call_tool(token, 'list_leads', limit: 50)
      expect(second['count']).to eq(2)

      _r, is_error, text = call_tool(token, 'list_leads')
      expect(is_error).to be(true)
      expect(text).to include('Daily limit of 4 records')
    end

    it 'records every call with who, which app and how many rows' do
      lead!
      call_tool(token, 'list_leads')

      expect(McpToolCall.last).to have_attributes(user_id: user.id, company_id: company.id, client_name: 'Claude',
                                                  tool_name: 'list_leads', status: 'ok', result_count: 1)
    end
  end

  describe 'write tools' do
    it 'creates a lead owned by the user and refuses a duplicate email' do
      created, = call_tool(token, 'create_lead', first_name: 'Sam', last_name: 'Reed', email: 'sam@example.com')
      lead = Lead.find(created.dig('created', 'id').split(':').last)
      expect(lead).to have_attributes(company_id: company.id, owner_id: user.id, origin: 'ai_connector')

      _r, is_error, text = call_tool(token, 'create_lead', first_name: 'Sam', email: 'SAM@example.com')
      expect(is_error).to be(true)
      expect(text).to include("lead:#{lead.id}")
    end

    it "does not name a duplicate lead the user cannot see" do
      lead!(email: 'hidden@example.com', location_id: boulder.id)
      local = connect!(connector_user(company, { 'leads' => %w[read create] }, location: denver))['access_token']

      _r, is_error, text = call_tool(local, 'create_lead', first_name: 'X', email: 'hidden@example.com')
      expect(is_error).to be(true)
      expect(text).to eq('A lead with that email already exists.')
    end

    it 'adds a note to the notes timeline without touching the notes field' do
      lead = lead!(notes: 'original intake notes')
      call_tool(token, 'add_note', id: "lead:#{lead.id}", text: 'Called, left a voicemail')

      expect(Note.where(entity_type: 'lead', entity_id: lead.id.to_s).pluck(:content)).to eq(['Called, left a voicemail'])
      expect(lead.reload.notes).to eq('original intake notes')
    end

    it "only accepts the company's own lead statuses" do
      company.lead_statuses.create!(key: 'contacted', label: 'Contacted', sort_order: 1, is_active: true)
      lead = lead!

      _r, is_error, text = call_tool(token, 'update_lead_status', id: "lead:#{lead.id}", status: 'hot')
      expect(is_error).to be(true)
      expect(text).to include('contacted')

      call_tool(token, 'update_lead_status', id: "lead:#{lead.id}", status: 'contacted')
      expect(lead.reload.status).to eq('contacted')
    end

    it 'assigns a lead only to an active user in the same company' do
      lead = lead!
      rep = connector_user(company, {})
      outsider = connector_user(connector_company, {})

      _r, is_error, = call_tool(token, 'assign_lead', id: "lead:#{lead.id}", user_id: outsider.id)
      expect(is_error).to be(true)

      call_tool(token, 'assign_lead', id: "lead:#{lead.id}", user_id: rep.id)
      expect(lead.reload.owner_id).to eq(rep.id)
    end

    it 'moves a deal stage with history, and refuses an unknown stage' do
      deal = company.deals.create!(name: 'Reed home', stage: 'proposal', contact_id: buyer.id, location_id: denver.id)

      _r, is_error, = call_tool(token, 'update_deal_stage', id: "deal:#{deal.id}", stage: 'sold-ish')
      expect(is_error).to be(true)

      call_tool(token, 'update_deal_stage', id: "deal:#{deal.id}", stage: 'negotiation', note: 'Counter at 118k')
      expect(deal.reload.stage).to eq('negotiation')
      expect(deal.deal_stage_histories.last).to have_attributes(previous_stage: 'proposal', changed_by_id: user.id,
                                                                notes: 'Counter at 118k')
    end

    it 'creates a task linked to a lead and a service ticket for a contact' do
      lead = lead!
      contact = buyer

      task, = call_tool(token, 'create_task', title: 'Send floor plans', due_date: 1.day.from_now.to_date.iso8601,
                                             related_id: "lead:#{lead.id}")
      created = Task.find(task.dig('created', 'id').split(':').last)
      expect(created).to have_attributes(taskable_type: 'Lead', taskable_id: lead.id, assigned_to_id: user.id)
      # A date alone means the end of that day where the dealer is, not midnight UTC.
      expect(created.due_date.in_time_zone('America/Denver').strftime('%Y-%m-%d %H:%M'))
        .to eq("#{1.day.from_now.to_date.iso8601} 17:00")

      ticket, = call_tool(token, 'create_service_ticket', title: 'Leaking skylight', description: 'Front bedroom',
                                                         customer_id: "contact:#{contact.id}")
      expect(ServiceTicket.find(ticket.dig('created', 'id').split(':').last))
        .to have_attributes(contact_id: contact.id, location_id: denver.id, assigned_to: user.id.to_s)
    end

    it 'refuses writes the role does not allow, even on a write connection' do
      reader = connect!(connector_user(company, { 'leads' => %w[read] }))['access_token']
      lead = lead!

      _r, is_error, text = call_tool(reader, 'update_lead_status', id: "lead:#{lead.id}", status: 'new')
      expect(is_error).to be(true)
      expect(text).to include('does not allow update on leads')
    end
  end

  describe 'reference data and summaries' do
    it 'names the statuses, stages, people and locations the other tools take' do
      denver
      data, = call_tool(token, 'get_reference_data')

      expect(data['you']).to include('id' => user.id)
      expect(data['deal_stages'].map { |s| s['key'] }).to include('proposal', 'closed_won')
      expect(data['locations'].map { |l| l['name'] }).to include('Denver')
    end

    it 'summarizes the pipeline without spending the record budget' do
      company.deals.create!(name: 'A', stage: 'proposal', selling_price: 100_000, contact_id: buyer.id, location_id: denver.id)
      lead!
      summary, = call_tool(token, 'pipeline_summary')

      expect(summary['open_deals_by_stage']).to include(include('stage' => 'proposal', 'count' => 1, 'total_selling_price' => 100_000.0))
      expect(summary['new_leads_last_7_days']).to eq(1)
      expect(McpToolCall.last.result_count).to eq(0)
    end
  end
end
