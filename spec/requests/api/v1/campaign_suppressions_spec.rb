# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Api::V1::CampaignSuppressions", type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "T", last_name: "U",
                 password: "Pass1234!", company_id: company.id, role: "platform_admin")
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }

  describe "POST /api/v1/campaign_suppressions" do
    it "creates a manual suppression" do
      post "/api/v1/campaign_suppressions",
           params: { email_address: "Spam@Foo.com", reason: "manual", notes: "no" }.to_json,
           headers: auth_headers
      expect(response).to have_http_status(:created)
      s = CampaignSuppression.find_by(company_id: company.id, email_address: "spam@foo.com")
      expect(s).to be_present
    end

    it "rejects invalid reason" do
      post "/api/v1/campaign_suppressions",
           params: { email_address: "x@y.com", reason: "bogus" }.to_json,
           headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /api/v1/campaign_suppressions" do
    it "scopes by company and supports search" do
      CampaignSuppression.create!(company_id: company.id, email_address: "a@example.com", reason: "manual")
      other = Company.create!(name: "Other")
      CampaignSuppression.create!(company_id: other.id, email_address: "x@example.com", reason: "manual")

      get "/api/v1/campaign_suppressions", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      emails = body["items"].map { |s| s["email_address"] }
      expect(emails).to include("a@example.com")
      expect(emails).not_to include("x@example.com")
    end
  end

  describe "DELETE /api/v1/campaign_suppressions/:id" do
    it "deletes a suppression in the company" do
      s = CampaignSuppression.create!(company_id: company.id, email_address: "x@y.com", reason: "manual")
      delete "/api/v1/campaign_suppressions/#{s.id}", headers: auth_headers
      expect(response).to have_http_status(:no_content)
      expect(CampaignSuppression.find_by(id: s.id)).to be_nil
    end

    it "returns 404 for cross-company id" do
      other = Company.create!(name: "Other")
      s = CampaignSuppression.create!(company_id: other.id, email_address: "x@y.com", reason: "manual")
      delete "/api/v1/campaign_suppressions/#{s.id}", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
