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
end
