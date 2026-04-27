# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Api::V1::CampaignTemplates", type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "T", last_name: "U",
                 password: "Pass1234!", company_id: company.id, role: "platform_admin")
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }

  let!(:seeded) do
    CampaignTemplate.create!(slug: "p-#{SecureRandom.hex(4)}", name: "Seeded",
      category: "b2b_saas_sales", vertical: "b2b", is_seeded: true,
      steps_template: [{ "wait_days" => 0, "subject" => "Hi", "body_blocks" => [{ "type" => "text", "html" => "hi" }] }],
      audience_hint: { "source_type" => "Lead" })
  end

  describe "GET /api/v1/campaign_templates" do
    it "lists seeded + company-owned templates" do
      get "/api/v1/campaign_templates", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      slugs = body["items"].map { |t| t["slug"] }
      expect(slugs).to include(seeded.slug)
    end
  end

  describe "POST /api/v1/campaign_templates/:id/instantiate" do
    it "creates a campaign from the template" do
      params = { from_identity_type: "User", from_identity_id: user.id, name: "From Template" }
      post "/api/v1/campaign_templates/#{seeded.id}/instantiate",
           params: params.to_json, headers: auth_headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      campaign = Campaign.find(body["id"])
      expect(campaign.company_id).to eq(company.id)
      expect(campaign.campaign_steps.count).to eq(1)
      expect(campaign.campaign_audience.source_type).to eq("Lead")
      expect(campaign.seeded_from_template_id).to eq(seeded.id)
    end

    it "returns 422 when from_identity_type is missing" do
      post "/api/v1/campaign_templates/#{seeded.id}/instantiate",
           params: {}.to_json, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
