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

    it "excludes archived campaigns from the default view but surfaces them when filtered" do
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "Active one",
                       campaign_type: "blast", from_identity_type: "User",
                       from_identity_id: user.id, throttle_per_day: 100, status: "draft")
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "Archived one",
                       campaign_type: "blast", from_identity_type: "User",
                       from_identity_id: user.id, throttle_per_day: 100, status: "archived")

      get "/api/v1/campaigns", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      names = body["items"].map { |c| c["name"] }
      expect(names).to include("Active one")
      expect(names).not_to include("Archived one")
      # "Total" tile backs the default view, so it also excludes archived.
      expect(body.dig("meta", "stats", "total")).to eq(1)
      expect(body.dig("meta", "stats", "archived")).to eq(1)

      get "/api/v1/campaigns", params: { status: "archived" }, headers: auth_headers
      archived_names = JSON.parse(response.body)["items"].map { |c| c["name"] }
      expect(archived_names).to eq(["Archived one"])
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

    it "snapshots a saved audience onto the campaign when saved_audience_id is provided" do
      saved = Audience.create!(
        company: company, name: "Hot Leads", source_type: "Lead",
        filter_tree: { 'type' => 'and', 'children' => [{ 'field' => 'status', 'operator' => 'equals', 'value' => 'qualified' }] }
      )
      payload = create_payload.merge(saved_audience_id: saved.id)
      post "/api/v1/campaigns", params: payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      campaign = Campaign.find(body["id"])
      expect(campaign.campaign_audience).not_to be_nil
      expect(campaign.campaign_audience.saved_audience_id).to eq(saved.id)
      expect(campaign.campaign_audience.filter_tree).to eq(saved.filter_tree)
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

  describe "SMS channel (Phase A.5)" do
    let(:sms_create_payload) do
      {
        campaign: {
          name: "SMS Blast",
          campaign_type: "blast",
          channel: "sms",
          # User passes User as identity, but the model forces Company
          from_identity_type: "User",
          from_identity_id: user.id
        }
      }
    end

    it "creates an SMS campaign with auto-coerced identity to Company" do
      post "/api/v1/campaigns", params: sms_create_payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["channel"]).to eq("sms")
      expect(body["from_identity_type"]).to eq("Company")
      expect(body["from_identity_id"]).to eq(company.id)
    end

    it "start endpoint returns SMS-specific reason when no TwilioAccount" do
      post "/api/v1/campaigns", params: sms_create_payload.to_json, headers: auth_headers
      campaign = Campaign.find(JSON.parse(response.body)["id"])
      campaign.campaign_steps.create!(position: 0, is_active: true, sms_body: "Hi {{first_name}}")
      campaign.create_campaign_audience!(source_type: "Lead")

      post "/api/v1/campaigns/#{campaign.id}/start", headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["reasons"]).to include(a_string_matching(/active SMS number/i))
    end

    it "start endpoint succeeds for SMS campaign with TwilioAccount + steps + audience" do
      TwilioAccount.create!(company_id: company.id, phone_number: "+15551112222", phone_number_sid: "PN1", status: "active")
      post "/api/v1/campaigns", params: sms_create_payload.to_json, headers: auth_headers
      campaign = Campaign.find(JSON.parse(response.body)["id"])
      campaign.campaign_steps.create!(position: 0, is_active: true, sms_body: "Hi {{first_name}}")
      campaign.create_campaign_audience!(source_type: "Lead")

      post "/api/v1/campaigns/#{campaign.id}/start", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(campaign.reload.status).to eq("running")
    end
  end

  describe "phase B endpoints" do
    let(:campaign) do
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "L",
                       campaign_type: "blast", from_identity_type: "User",
                       from_identity_id: user.id, throttle_per_day: 100)
    end

    it "test_send rejects when no active steps configured" do
      post "/api/v1/campaigns/#{campaign.id}/test_send", headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/no active steps/i)
    end

    it "preview rejects when no active steps configured" do
      get "/api/v1/campaigns/#{campaign.id}/preview", headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/no active steps/i)
    end

    it "ai_generate requires a prompt" do
      post "/api/v1/campaigns/ai_generate", headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/prompt is required/i)
    end
  end

  # ============================================================
  # Phase E — analytics_timeseries
  # ============================================================
  describe "GET /api/v1/campaigns/:id/analytics_timeseries" do
    let(:campaign) do
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "TS",
                       campaign_type: "blast", from_identity_type: "User",
                       from_identity_id: user.id, throttle_per_day: 100)
    end

    it "returns 200 with buckets and totals" do
      get "/api/v1/campaigns/#{campaign.id}/analytics_timeseries", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["campaign_id"]).to eq(campaign.id)
      expect(body["buckets"]).to be_an(Array)
      expect(body["totals"]).to be_a(Hash)
      expect(body["totals"]).to include("sent", "opened", "clicked", "replied", "bounced", "delivered")
    end

    it "defaults to 30 days when no param provided" do
      get "/api/v1/campaigns/#{campaign.id}/analytics_timeseries", headers: auth_headers
      body = JSON.parse(response.body)
      expect(body["days"]).to eq(30)
      expect(body["buckets"].size).to eq(30)
    end
  end

  describe "GET /api/v1/campaigns/merge_fields" do
    it "returns 200 with fields and grouped keys (defaults to Lead)" do
      get "/api/v1/campaigns/merge_fields", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["source_type"]).to eq("Lead")
      expect(body["fields"]).to be_an(Array)
      expect(body["grouped"]).to be_a(Hash)
      keys = body["fields"].map { |f| f["key"] }
      expect(keys).to include("first_name", "rep_name", "company.name")
    end

    it "filters by source_type=Account" do
      get "/api/v1/campaigns/merge_fields?source_type=Account", headers: auth_headers
      body = JSON.parse(response.body)
      keys = body["fields"].map { |f| f["key"] }
      expect(keys).to include("account_name")
      expect(keys).not_to include("first_name")
    end

    it "filters by channel=sms (excludes email-only fields)" do
      get "/api/v1/campaigns/merge_fields?channel=sms", headers: auth_headers
      body = JSON.parse(response.body)
      keys = body["fields"].map { |f| f["key"] }
      expect(keys).not_to include("unsubscribe_url", "rep_email")
      expect(keys).to include("phone")
    end
  end

  describe "GET /api/v1/campaigns/audience_field_schema" do
    it "returns 200 with fields and operator_labels (defaults to Lead)" do
      get "/api/v1/campaigns/audience_field_schema", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["source_type"]).to eq("Lead")
      expect(body["fields"]).to be_an(Array)
      expect(body["operator_labels"]).to be_a(Hash)
      tags_field = body["fields"].find { |f| f["key"] == "tags" }
      expect(tags_field["type"]).to eq("tags")
    end

    it "returns Account fields when source_type=Account" do
      get "/api/v1/campaigns/audience_field_schema?source_type=Account", headers: auth_headers
      body = JSON.parse(response.body)
      keys = body["fields"].map { |f| f["key"] }
      expect(keys).to include("name", "account_type")
      expect(keys).not_to include("first_name")
    end
  end
end
