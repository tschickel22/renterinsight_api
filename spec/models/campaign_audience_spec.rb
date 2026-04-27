# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CampaignAudience, type: :model do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:user) { User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "T", last_name: "U", password: "Pass1234!", company_id: company.id) }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id,
                     name: "C", campaign_type: "blast", from_identity_type: "User",
                     from_identity_id: user.id, throttle_per_day: 100)
  end

  it "validates source_type inclusion" do
    a = campaign.build_campaign_audience(source_type: "Bogus")
    expect(a).not_to be_valid
  end

  it "accepts Lead/Contact/Account" do
    %w[Lead Contact Account].each do |st|
      a = campaign.build_campaign_audience(source_type: st)
      expect(a).to be_valid
    end
  end

  describe "#compute_matches" do
    it "returns the company-scoped lead relation for source_type Lead" do
      audience = campaign.create_campaign_audience!(source_type: "Lead")
      expect(audience.compute_matches.model).to eq(Lead)
      expect(audience.compute_matches.where_values_hash["company_id"]).to eq(company.id)
    end
  end

  # ============================================================
  # Phase A.5 — SMS opt-in compliance
  # ============================================================
  describe "#compute_matches for SMS campaigns" do
    let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
    let(:sms_campaign) do
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "SMS",
                       campaign_type: "blast", channel: "sms",
                       from_identity_type: "User", from_identity_id: user.id, throttle_per_day: 100)
    end
    let!(:lead_in)  { Lead.create!(company: company, source: source, first_name: "A", last_name: "1", email: "a@e.com", opt_in_sms: true) }
    let!(:lead_out) { Lead.create!(company: company, source: source, first_name: "B", last_name: "2", email: "b@e.com", opt_in_sms: false) }

    it "auto-applies opt_in_sms filter when channel is sms (no override)" do
      audience = sms_campaign.create_campaign_audience!(source_type: "Lead")
      ids = audience.compute_matches.pluck(:id)
      expect(ids).to include(lead_in.id)
      expect(ids).not_to include(lead_out.id)
    end

    it "skips the opt-in filter when sms_compliance_override is acknowledged" do
      audience = sms_campaign.create_campaign_audience!(
        source_type: "Lead",
        metadata: { 'compliance_override_acknowledged' => 'true' }
      )
      ids = audience.compute_matches.pluck(:id)
      expect(ids).to include(lead_in.id, lead_out.id)
    end

    it "returns .none for source_type='Account' on SMS (Accounts have no opt-in field)" do
      audience = sms_campaign.create_campaign_audience!(source_type: "Account")
      expect(audience.compute_matches).to be_empty
    end
  end
end
