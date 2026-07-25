# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Public Referrals", type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "T", last_name: "U",
                 password: "Pass1234!", company_id: company.id, role: "platform_admin")
  end
  let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
  let(:referrer) { Lead.create!(company: company, source: source, first_name: "Reba", last_name: "Referrer", email: "reba-#{SecureRandom.hex(4)}@example.com") }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "Spring Blast",
      campaign_type: "blast", from_identity_type: "User", from_identity_id: user.id, throttle_per_day: 100)
  end
  let(:step) { campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ "type" => "text", "html" => "x" }]) }
  let(:enrollment) { CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: "Lead", recipient_id: referrer.id, email_address_snapshot: referrer.email) }
  let(:cs) { CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id, campaign_enrollment_id: enrollment.id) }

  let(:raw_token) { Rails.application.message_verifier(:campaign_referral).generate({ "s" => cs.id }) }

  # Force the send chain (and the referrer Lead) into existence before any
  # example body runs, so change{leads.count} deltas count only the friend.
  before { raw_token }

  describe "GET /api/referrals/:token" do
    it "returns 404 for an invalid token" do
      get "/api/referrals/garbage"
      expect(response).to have_http_status(:not_found)
    end

    it "returns page context for a valid token" do
      get "/api/referrals/#{raw_token}"
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["company_name"]).to eq(company.name)
      expect(body["referrer_first_name"]).to eq("Reba")
      expect(body).to have_key("captcha_required")
    end
  end

  describe "POST /api/referrals/:token" do
    it "returns 404 for an invalid token" do
      post "/api/referrals/garbage", params: { friend_email: "f@example.com" }
      expect(response).to have_http_status(:not_found)
    end

    it "rejects an invalid friend email" do
      post "/api/referrals/#{raw_token}", params: { friend_email: "not-an-email" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "creates a Lead attributed to the referrer with source Referral" do
      email = "friend-#{SecureRandom.hex(4)}@example.com"
      expect {
        post "/api/referrals/#{raw_token}", params: { friend_email: email, friend_first_name: "Fran", note: "you'll love it" }
      }.to change { company.leads.count }.by(1)
      expect(response).to have_http_status(:ok)

      lead = company.leads.where("LOWER(email) = ?", email).first
      expect(lead).to be_present
      expect(lead.first_name).to eq("Fran")
      expect(lead.source.name).to eq("Referral")
      expect(lead.custom_field_values["referred_by_lead_id"]).to eq(referrer.id)
      expect(lead.custom_field_values["referred_by_campaign_send_id"]).to eq(cs.id)
      expect(lead.notes).to include("Reba Referrer")
    end

    it "dedupes onto an existing lead instead of creating a duplicate" do
      existing = Lead.create!(company: company, source: source, first_name: "Dup", email: "dup-#{SecureRandom.hex(4)}@example.com")
      expect {
        post "/api/referrals/#{raw_token}", params: { friend_email: existing.email.upcase }
      }.not_to change { company.leads.count }
      expect(response).to have_http_status(:ok)
    end

    it "does not create a lead for a suppressed email" do
      email = "opted-out-#{SecureRandom.hex(4)}@example.com"
      CampaignSuppression.create!(company_id: company.id, email_address: email, reason: "unsubscribe")
      expect {
        post "/api/referrals/#{raw_token}", params: { friend_email: email }
      }.not_to change { company.leads.count }
      expect(response).to have_http_status(:ok)
    end
  end
end
