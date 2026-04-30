# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Api::V1::Audiences", type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com",
      first_name: "T", last_name: "U",
      password: "Pass1234!", company_id: company.id,
      role: "platform_admin"
    )
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }
  let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }

  def make_audience(co, attrs = {})
    Audience.create!({
      company: co, name: "Aud-#{SecureRandom.hex(3)}",
      source_type: 'Lead',
      filter_tree: { 'type' => 'and', 'children' => [] }
    }.merge(attrs))
  end

  describe "GET /api/v1/audiences" do
    it "returns 401 without auth" do
      get "/api/v1/audiences"
      expect(response).to have_http_status(:unauthorized)
    end

    it "scopes to current company" do
      mine = make_audience(company, name: 'Mine')
      other = Company.create!(name: "Other")
      _theirs = make_audience(other, name: 'Theirs')

      get "/api/v1/audiences", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      names = body['items'].map { |a| a['name'] }
      expect(names).to include('Mine')
      expect(names).not_to include('Theirs')
      expect(body['meta']['stats']['total']).to eq(1)
      expect(body['meta']['stats']['lead']).to eq(1)
    end

    it "filters by source_type" do
      make_audience(company, name: 'Lead Aud', source_type: 'Lead')
      make_audience(company, name: 'Account Aud', source_type: 'Account')

      get "/api/v1/audiences", params: { source_type: 'Account' }, headers: auth_headers
      body = JSON.parse(response.body)
      expect(body['items'].map { |a| a['name'] }).to contain_exactly('Account Aud')
    end

    it "search by name" do
      make_audience(company, name: 'Hot Leads')
      make_audience(company, name: 'Cold Leads')
      get "/api/v1/audiences", params: { search: 'Hot' }, headers: auth_headers
      body = JSON.parse(response.body)
      expect(body['items'].map { |a| a['name'] }).to contain_exactly('Hot Leads')
    end
  end

  describe "POST /api/v1/audiences" do
    it "creates with valid filter_tree and computes estimate" do
      Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@e.com', status: 'new')
      payload = { audience: { name: 'New Audience', source_type: 'Lead', filter_tree: { type: 'and', children: [{ field: 'status', operator: 'equals', value: 'new' }] } } }
      post "/api/v1/audiences", params: payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['name']).to eq('New Audience')
      expect(body['estimated_count']).to eq(1)
      expect(body['estimated_at']).not_to be_nil
    end

    it "422 when name is missing" do
      payload = { audience: { source_type: 'Lead', filter_tree: { type: 'and', children: [] } } }
      post "/api/v1/audiences", params: payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /api/v1/audiences/:id" do
    it "updates filter_tree and recomputes estimate" do
      Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@e.com', status: 'qualified')
      a = make_audience(company)
      payload = { audience: { filter_tree: { type: 'and', children: [{ field: 'status', operator: 'equals', value: 'qualified' }] } } }
      patch "/api/v1/audiences/#{a.id}", params: payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['estimated_count']).to eq(1)
    end
  end

  describe "DELETE /api/v1/audiences/:id" do
    it "204 when no campaigns reference it" do
      a = make_audience(company)
      delete "/api/v1/audiences/#{a.id}", headers: auth_headers
      expect(response).to have_http_status(:no_content)
    end

    it "422 when used by a campaign" do
      a = make_audience(company)
      campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                                  campaign_type: 'blast', from_identity_type: 'User',
                                  from_identity_id: user.id, throttle_per_day: 100)
      campaign.create_campaign_audience!(source_type: 'Lead', saved_audience_id: a.id)
      delete "/api/v1/audiences/#{a.id}", headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/used by/)
    end
  end

  describe "archive / unarchive" do
    it "round-trips" do
      a = make_audience(company)
      post "/api/v1/audiences/#{a.id}/archive", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(a.reload.is_archived).to eq(true)
      post "/api/v1/audiences/#{a.id}/unarchive", headers: auth_headers
      expect(a.reload.is_archived).to eq(false)
    end
  end

  describe "POST /api/v1/audiences/:id/preview" do
    it "returns count + sample with custom filter_tree" do
      Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@e.com', status: 'new')
      a = make_audience(company)
      payload = { filter_tree: { type: 'and', children: [{ field: 'status', operator: 'equals', value: 'new' }] } }
      post "/api/v1/audiences/#{a.id}/preview", params: payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['count']).to eq(1)
      expect(body['sample']).to be_an(Array)
    end
  end

  describe "POST /api/v1/audiences/preview_dry_run" do
    it "previews unsaved filter trees" do
      Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@e.com', status: 'new')
      payload = { source_type: 'Lead', filter_tree: { type: 'and', children: [] } }
      post "/api/v1/audiences/preview_dry_run", params: payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['count']).to eq(1)
      expect(body['source_type']).to eq('Lead')
    end
  end

  describe "AI endpoints" do
    def stub_claude_response(filter_tree, status: '200')
      body = {
        'content' => [{ 'type' => 'text', 'text' => filter_tree.to_json }],
        'usage' => { 'input_tokens' => 800, 'output_tokens' => 200 }
      }.to_json
      response = instance_double(Net::HTTPResponse, code: status, body: body)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:request).and_return(response)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('ANTHROPIC_API_KEY').and_return('test-key')
    end

    it "ai_generate returns generation_id and preview" do
      Lead.create!(company: company, source: source, first_name: 'A', last_name: 'B', email: 'a@e.com', status: 'new')
      stub_claude_response({ 'type' => 'and', 'children' => [{ 'field' => 'status', 'operator' => 'equals', 'value' => 'new' }] })
      payload = { prompt: 'all new leads', source_type: 'Lead' }
      post "/api/v1/audiences/ai_generate", params: payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['generation_id']).to be_present
      expect(body['preview']['count']).to eq(1)
    end

    it "ai_refine creates child generation" do
      stub_claude_response({ 'type' => 'and', 'children' => [] })
      gen = AudienceAiGeneration.create!(company: company, user: user, prompt: 'p', source_type: 'Lead',
                                          generated_filter_tree: { 'type' => 'and', 'children' => [] }, status: 'generated')
      payload = { generation_id: gen.id, feedback: 'narrower' }
      post "/api/v1/audiences/ai_refine", params: payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['parent_id']).to eq(gen.id)
    end

    it "ai_accept creates audience and marks generation accepted" do
      gen = AudienceAiGeneration.create!(company: company, user: user, prompt: 'p', source_type: 'Lead',
                                          generated_filter_tree: { 'type' => 'and', 'children' => [] }, status: 'generated')
      payload = { generation_id: gen.id, name: 'Saved!' }
      post "/api/v1/audiences/ai_accept", params: payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['name']).to eq('Saved!')
      expect(gen.reload.status).to eq('accepted')
    end
  end

  describe "tenant isolation" do
    it "404 for audience from another company" do
      other = Company.create!(name: 'Other')
      a = make_audience(other)
      get "/api/v1/audiences/#{a.id}", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
