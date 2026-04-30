# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Api::V1::CampaignSteps", type: :request do
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

  let(:campaign) do
    Campaign.create!(
      company_id: company.id, created_by_user_id: user.id, name: "Steps Test",
      campaign_type: "drip", status: "draft",
      from_identity_type: "User", from_identity_id: user.id,
      throttle_per_day: 100
    )
  end

  let(:step) do
    campaign.campaign_steps.create!(
      position: 0, channel: "email", wait_days: 0, wait_hours: 0,
      subject: "Welcome", is_active: true,
      body_blocks: [{ "type" => "text", "html" => "<p>Hello</p>" }]
    )
  end

  # ==================== CREATE ====================

  describe "POST /api/v1/campaigns/:campaign_id/steps" do
    let(:step_payload) do
      {
        campaign_step: {
          channel: "email",
          wait_days: 3,
          wait_hours: 0,
          subject: "Follow up",
          preheader: "Don't miss out",
          body_blocks: [{ "type" => "text", "html" => "<p>Hi there</p>" }],
          is_active: true
        }
      }
    end

    it "returns 401 without auth" do
      post "/api/v1/campaigns/#{campaign.id}/steps", params: step_payload.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "creates a step on a draft campaign" do
      post "/api/v1/campaigns/#{campaign.id}/steps", params: step_payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["subject"]).to eq("Follow up")
      expect(body["wait_days"]).to eq(3)
      expect(body["preheader"]).to eq("Don't miss out")
      expect(body["is_active"]).to eq(true)
      expect(body["id"]).to be_present
    end

    it "auto-assigns position when not provided" do
      campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [])
      campaign.campaign_steps.create!(position: 1, is_active: true, body_blocks: [])

      payload = { campaign_step: { channel: "email", wait_days: 5, body_blocks: [] } }
      post "/api/v1/campaigns/#{campaign.id}/steps", params: payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["position"]).to eq(2)
    end

    it "returns 422 when campaign is running (locked)" do
      campaign.update!(status: "running", started_at: Time.current)
      post "/api/v1/campaigns/#{campaign.id}/steps", params: step_payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["error"]).to match(/locked/i)
    end

    it "returns 422 when campaign is completed" do
      campaign.update!(status: "completed")
      post "/api/v1/campaigns/#{campaign.id}/steps", params: step_payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "allows create on a scheduled campaign" do
      campaign.update!(status: "scheduled")
      post "/api/v1/campaigns/#{campaign.id}/steps", params: step_payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:created)
    end

    it "returns 404 for another company's campaign (tenant isolation)" do
      other_company = Company.create!(name: "Other")
      other_user = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: "O", last_name: "U", password: "Pass1234!", company_id: other_company.id)
      foreign_campaign = Campaign.create!(
        company_id: other_company.id, created_by_user_id: other_user.id, name: "Foreign",
        campaign_type: "blast", from_identity_type: "User", from_identity_id: other_user.id,
        throttle_per_day: 100
      )

      post "/api/v1/campaigns/#{foreign_campaign.id}/steps", params: step_payload.to_json, headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # ==================== UPDATE ====================

  describe "PATCH /api/v1/campaigns/:campaign_id/steps/:id" do
    it "updates step fields" do
      patch "/api/v1/campaigns/#{campaign.id}/steps/#{step.id}",
            params: { campaign_step: { subject: "Updated Subject", wait_days: 7 } }.to_json,
            headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["subject"]).to eq("Updated Subject")
      expect(body["wait_days"]).to eq(7)
    end

    it "returns 422 when campaign is running (locked)" do
      campaign.update!(status: "running", started_at: Time.current)
      patch "/api/v1/campaigns/#{campaign.id}/steps/#{step.id}",
            params: { campaign_step: { subject: "X" } }.to_json,
            headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["error"]).to match(/locked/i)
    end

    it "returns 404 for step in another company's campaign" do
      other_company = Company.create!(name: "Other")
      other_user = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: "O", last_name: "U", password: "Pass1234!", company_id: other_company.id)
      foreign_campaign = Campaign.create!(
        company_id: other_company.id, created_by_user_id: other_user.id, name: "Foreign",
        campaign_type: "blast", from_identity_type: "User", from_identity_id: other_user.id,
        throttle_per_day: 100
      )
      foreign_step = foreign_campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [])

      patch "/api/v1/campaigns/#{foreign_campaign.id}/steps/#{foreign_step.id}",
            params: { campaign_step: { subject: "Hacked" } }.to_json,
            headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # ==================== DESTROY ====================

  describe "DELETE /api/v1/campaigns/:campaign_id/steps/:id" do
    it "removes a step from a draft campaign" do
      delete "/api/v1/campaigns/#{campaign.id}/steps/#{step.id}", headers: auth_headers
      expect(response).to have_http_status(:no_content)
      expect(campaign.campaign_steps.find_by(id: step.id)).to be_nil
    end

    it "returns 422 when campaign is running (locked)" do
      campaign.update!(status: "running", started_at: Time.current)
      delete "/api/v1/campaigns/#{campaign.id}/steps/#{step.id}", headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 404 for step in another company's campaign" do
      other_company = Company.create!(name: "Other")
      other_user = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: "O", last_name: "U", password: "Pass1234!", company_id: other_company.id)
      foreign_campaign = Campaign.create!(
        company_id: other_company.id, created_by_user_id: other_user.id, name: "Foreign",
        campaign_type: "blast", from_identity_type: "User", from_identity_id: other_user.id,
        throttle_per_day: 100
      )
      foreign_step = foreign_campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [])

      delete "/api/v1/campaigns/#{foreign_campaign.id}/steps/#{foreign_step.id}", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # ==================== AUTHORIZATION ====================

  describe "authorization (without campaigns.update permission)" do
    let(:unprivileged_user) do
      User.create!(
        email: "np-#{SecureRandom.hex(4)}@example.com",
        first_name: "N", last_name: "P",
        password: "Pass1234!", company_id: company.id,
        role: "user"
      )
    end
    let(:unprivileged_token) { JsonWebToken.encode(user_id: unprivileged_user.id, company_id: company.id) }
    let(:unprivileged_headers) do
      { "Authorization" => "Bearer #{unprivileged_token}", "Content-Type" => "application/json" }
    end

    before do
      allow_any_instance_of(Api::V1::CampaignStepsController)
        .to receive(:authorize_action!) do |controller, resource, action|
          if resource == 'campaigns' && action == 'update'
            controller.send(:render, json: { error: 'Forbidden' }, status: :forbidden)
            false
          else
            true
          end
        end
    end

    it "returns 403 on POST create" do
      payload = {
        campaign_step: {
          channel: "email", wait_days: 0, subject: "Hi",
          body_blocks: [{ "type" => "text", "html" => "<p>x</p>" }],
          is_active: true
        }
      }
      post "/api/v1/campaigns/#{campaign.id}/steps",
           params: payload.to_json, headers: unprivileged_headers

      expect(response).to have_http_status(:forbidden)
      expect(campaign.campaign_steps.count).to eq(0)
    end

    it "returns 403 on PATCH update" do
      patch "/api/v1/campaigns/#{campaign.id}/steps/#{step.id}",
            params: { campaign_step: { subject: "Hacked" } }.to_json,
            headers: unprivileged_headers

      expect(response).to have_http_status(:forbidden)
      expect(step.reload.subject).to eq("Welcome")
    end

    it "returns 403 on DELETE destroy" do
      step_to_delete = step
      delete "/api/v1/campaigns/#{campaign.id}/steps/#{step_to_delete.id}",
             headers: unprivileged_headers

      expect(response).to have_http_status(:forbidden)
      expect(CampaignStep.where(id: step_to_delete.id)).to exist
    end
  end
end
