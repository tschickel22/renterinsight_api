# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Public CampaignTracking", type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "T", last_name: "U",
                 password: "Pass1234!", company_id: company.id, role: "platform_admin")
  end
  let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
  let(:lead) { Lead.create!(company: company, source: source, first_name: "B", last_name: "1", email: "buyer-#{SecureRandom.hex(4)}@example.com") }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "C",
      campaign_type: "blast", from_identity_type: "User", from_identity_id: user.id, throttle_per_day: 100)
  end
  let(:step) { campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ "type" => "text", "html" => "x" }]) }
  let(:enrollment) { CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: "Lead", recipient_id: lead.id, email_address_snapshot: lead.email) }
  let(:cs) { CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id, campaign_enrollment_id: enrollment.id) }

  describe "GET /t/:token" do
    let!(:token) do
      CampaignLinkToken.create!(campaign_id: campaign.id, campaign_send_id: cs.id, target_url: "https://example.com/landing")
    end

    it "redirects to target_url and increments counters" do
      get "/t/#{token.token}"
      expect(response).to have_http_status(:found) # 302
      expect(response.location).to eq("https://example.com/landing")
      token.reload
      expect(token.click_count).to eq(1)
      expect(token.first_clicked_at).to be_present
      cs.reload
      expect(cs.click_count).to eq(1)
      expect(cs.clicked_at).to be_present
    end

    it "redirects to fallback URL when token is unknown" do
      get "/t/totally-bogus-token"
      expect(response).to have_http_status(:found)
      expect(response.location).to include("renterinsight.com")
    end
  end

  describe "/u/:token unsubscribe flow" do
    let(:raw_token) do
      Rails.application.message_verifier(:campaign_unsubscribe).generate({ "s" => cs.id })
    end

    it "returns 404 for invalid token" do
      get "/u/garbage"
      expect(response).to have_http_status(:not_found)
    end

    it "shows campaign info on GET /u/:token" do
      get "/u/#{raw_token}"
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["email_address"]).to eq(enrollment.email_address_snapshot)
      expect(body["already_unsubscribed"]).to be(false)
    end

    it "creates a suppression and marks enrollment unsubscribed on POST /u/:token" do
      expect {
        post "/u/#{raw_token}"
      }.to change { CampaignSuppression.where(company_id: company.id).count }.by(1)
      expect(response).to have_http_status(:ok)
      enrollment.reload
      expect(enrollment.status).to eq("unsubscribed")
      expect(enrollment.unsubscribed_at).to be_present
      cs.reload
      expect(cs.unsubscribed_at).to be_present
    end
  end
end
