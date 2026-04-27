# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Api::V1::Campaigns", type: :request do
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

  let(:create_payload) do
    {
      campaign: {
        name: "Spring Promo",
        campaign_type: "blast",
        from_identity_type: "User",
        from_identity_id: user.id,
        from_display_name: "T U"
      }
    }
  end

  describe "GET /api/v1/campaigns" do
    it "returns 401 without auth" do
      get "/api/v1/campaigns"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns campaigns scoped to user's company" do
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "A",
                       campaign_type: "blast", from_identity_type: "User",
                       from_identity_id: user.id, throttle_per_day: 100)

      other_company = Company.create!(name: "Other")
      other_user = User.create!(email: "x-#{SecureRandom.hex(4)}@example.com", first_name: "O", last_name: "U", password: "Pass1234!", company_id: other_company.id)
      Campaign.create!(company_id: other_company.id, created_by_user_id: other_user.id, name: "Z",
                       campaign_type: "blast", from_identity_type: "User",
                       from_identity_id: other_user.id, throttle_per_day: 100)

      get "/api/v1/campaigns", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      names = body["items"].map { |c| c["name"] }
      expect(names).to include("A")
      expect(names).not_to include("Z")
    end
  end

  describe "POST /api/v1/campaigns" do
    it "creates a campaign" do
      post "/api/v1/campaigns", params: create_payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["name"]).to eq("Spring Promo")
      expect(body["status"]).to eq("draft")
      expect(body["created_by_user_id"]).to eq(user.id)
    end

    it "rejects invalid params" do
      post "/api/v1/campaigns", params: { campaign: { name: "" } }.to_json, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "ignores attempts to set company_id from params (tenant isolation)" do
      foreign_company = Company.create!(name: "Foreign")
      payload = create_payload.deep_merge(campaign: { company_id: foreign_company.id })
      post "/api/v1/campaigns", params: payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      campaign = Campaign.find(body["id"])
      expect(campaign.company_id).to eq(company.id)
    end
  end

  describe "GET /api/v1/campaigns/:id" do
    let(:campaign) do
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "Show",
                       campaign_type: "blast", from_identity_type: "User",
                       from_identity_id: user.id, throttle_per_day: 100)
    end

    it "returns 404 for cross-company access" do
      other_company = Company.create!(name: "Other")
      other_user = User.create!(email: "x-#{SecureRandom.hex(4)}@example.com", first_name: "O", last_name: "U", password: "Pass1234!", company_id: other_company.id)
      foreign = Campaign.create!(company_id: other_company.id, created_by_user_id: other_user.id, name: "Foreign",
                                 campaign_type: "blast", from_identity_type: "User",
                                 from_identity_id: other_user.id, throttle_per_day: 100)
      get "/api/v1/campaigns/#{foreign.id}", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns the full campaign with steps and audience" do
      campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ "type" => "text", "html" => "x" }])
      campaign.create_campaign_audience!(source_type: "Lead")
      get "/api/v1/campaigns/#{campaign.id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["steps"].length).to eq(1)
      expect(body["audience"]["source_type"]).to eq("Lead")
    end
  end

  describe "lifecycle: start / pause / resume / archive" do
    let(:campaign) do
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "L",
                       campaign_type: "blast", from_identity_type: "User",
                       from_identity_id: user.id, throttle_per_day: 100)
    end

    it "rejects start when preconditions are not met" do
      post "/api/v1/campaigns/#{campaign.id}/start", headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["reasons"]).to be_an(Array)
      expect(body["reasons"].length).to be >= 1
    end

    it "starts when preconditions are met" do
      UserEmailConnection.create!(user_id: user.id, company_id: company.id,
        provider: "oauth_gmail", email_address: "u@e.com",
        oauth_token_encrypted: "x", oauth_refresh_token_encrypted: "y", is_active: true)
      campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ "type" => "text", "html" => "x" }])
      campaign.create_campaign_audience!(source_type: "Lead")
      post "/api/v1/campaigns/#{campaign.id}/start", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(campaign.reload.status).to eq("running")
    end

    it "pauses a running campaign and resumes it" do
      UserEmailConnection.create!(user_id: user.id, company_id: company.id, provider: "oauth_gmail",
        email_address: "u@e.com", oauth_token_encrypted: "x", oauth_refresh_token_encrypted: "y", is_active: true)
      campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ "type" => "text", "html" => "x" }])
      campaign.create_campaign_audience!(source_type: "Lead")
      post "/api/v1/campaigns/#{campaign.id}/start", headers: auth_headers
      post "/api/v1/campaigns/#{campaign.id}/pause", headers: auth_headers
      expect(campaign.reload.status).to eq("paused")
      post "/api/v1/campaigns/#{campaign.id}/resume", headers: auth_headers
      expect(campaign.reload.status).to eq("running")
    end
  end

  describe "phase B 501 endpoints" do
    let(:campaign) do
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "L",
                       campaign_type: "blast", from_identity_type: "User",
                       from_identity_id: user.id, throttle_per_day: 100)
    end

    it "test_send returns 501 in Phase A" do
      post "/api/v1/campaigns/#{campaign.id}/test_send", headers: auth_headers
      expect(response).to have_http_status(:not_implemented)
    end

    it "preview returns 501 in Phase A" do
      get "/api/v1/campaigns/#{campaign.id}/preview", headers: auth_headers
      expect(response).to have_http_status(:not_implemented)
    end

    it "ai_generate returns 501 in Phase A" do
      post "/api/v1/campaigns/ai_generate", headers: auth_headers
      expect(response).to have_http_status(:not_implemented)
    end
  end
end
