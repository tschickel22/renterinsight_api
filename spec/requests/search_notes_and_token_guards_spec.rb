# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/mcp_connector_helpers'

# B33 global search sees only what the person could open, B34 notes and lead
# activities respect locations and cannot be moved to another company, and
# B35 a refresh token is not a session.
RSpec.describe 'Search, notes and token guards', :mcp, type: :request do
  before { seed_rbac! }

  let(:company) { connector_company }
  let(:denver) { company.locations.create!(name: 'Denver', timezone: 'America/Denver') }
  let(:boulder) { company.locations.create!(name: 'Boulder', timezone: 'America/Denver') }
  let(:denver_rep) { connector_user(company, { 'leads' => %w[read update], 'crm' => %w[read create update delete] }, location: denver, connector: nil) }
  # Location limits as the app applies them: contacts (and most records) are
  # limited to the rep's locations. Leads are company wide for anyone whose
  # role reads all leads, as on the leads screen, so the lead activity case
  # below uses a rep whose only access is CRM.
  let!(:here) { company.contacts.create!(first_name: 'Zelda', last_name: 'Here', email: 'zh@example.com', location_id: denver.id) }
  let!(:there) { company.contacts.create!(first_name: 'Zelda', last_name: 'There', email: 'zt@example.com', location_id: boulder.id) }
  let(:crm_only_rep) { connector_user(company, { 'crm' => %w[read create update] }, location: denver, connector: nil) }
  let!(:lead_here) { company.leads.create!(first_name: 'L', last_name: 'Here', email: 'lh@example.com', status: 'new', location_id: denver.id) }
  let!(:lead_there) { company.leads.create!(first_name: 'L', last_name: 'There', email: 'lt@example.com', status: 'new', location_id: boulder.id) }

  def search(user, query)
    get '/api/v1/search/global', params: { query: query }, headers: app_headers(user)
    response.parsed_body['results'].map { |r| [r['type'], r['id']] }
  end

  describe 'global search (B33)' do
    it "finds contacts at the person's own location only" do
      found = search(denver_rep, 'Zelda')

      expect(found).to include(['contact', here.id])
      expect(found).not_to include(['contact', there.id])
    end

    it 'finds every location for an admin' do
      admin = connector_user(company, {}, role: 'company_admin')
      expect(search(admin, 'Zelda')).to include(['contact', here.id], ['contact', there.id])
    end

    it 'leaves out record types the role cannot read' do
      company.deals.create!(name: 'Zelda deal', stage: 'proposal', location_id: denver.id,
                            contact_id: company.contacts.create!(first_name: 'C', last_name: 'D', location_id: denver.id).id)
      found = search(denver_rep, 'Zelda')

      expect(found.map(&:first)).not_to include('deal')
    end
  end

  describe 'notes and lead activities (B34)' do
    def note_on(contact, user)
      post '/api/v1/notes', params: { note: { entity_type: 'contact', entity_id: contact.id, content: 'hi' } }.to_json,
                            headers: app_headers(user).merge('CONTENT_TYPE' => 'application/json')
    end

    it "will not read or write notes on another location's contact" do
      note_on(here, denver_rep)
      expect(response).to have_http_status(:created)

      note_on(there, denver_rep)
      expect(response).to have_http_status(:not_found)

      get '/api/v1/notes', params: { entity_type: 'contact', entity_id: there.id }, headers: app_headers(denver_rep)
      expect(response).to have_http_status(:not_found)
    end

    it "cannot move a note onto another company's record" do
      note = Note.create!(entity_type: 'contact', entity_id: here.id.to_s, content: 'mine', user_id: denver_rep.id)
      foreign = connector_company.leads.create!(first_name: 'X', last_name: 'Y', email: 'x@example.com', status: 'new')

      patch "/api/v1/notes/#{note.id}", params: { note: { content: 'moved', entity_id: foreign.id } }.to_json,
                                        headers: app_headers(denver_rep).merge('CONTENT_TYPE' => 'application/json')

      expect(note.reload).to have_attributes(content: 'moved', entity_id: here.id.to_s)
    end

    it "will not list or add activities on another location's lead" do
      get "/api/crm/leads/#{lead_there.id}/lead_activities", headers: app_headers(crm_only_rep)
      expect(response).to have_http_status(:not_found)

      get "/api/crm/leads/#{lead_here.id}/lead_activities", headers: app_headers(crm_only_rep)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'refresh tokens (B35)' do
    it 'are not accepted as a session, but still refresh' do
      refresh = JsonWebToken.generate_refresh_token(denver_rep)

      get '/api/crm/leads', headers: { 'Authorization' => "Bearer #{refresh}" }
      expect(response).to have_http_status(:unauthorized)

      # The endpoint the web app calls (apiClient and utils/api both use it).
      post '/api/auth/tokens/refresh', params: { refresh_token: refresh }
      expect(response).to have_http_status(:ok)
    end
  end
end
