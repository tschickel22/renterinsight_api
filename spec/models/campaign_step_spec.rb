# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CampaignStep, type: :model do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:user) { User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "T", last_name: "U", password: "Pass1234!", company_id: company.id) }
  let(:campaign) do
    Campaign.create!(
      company_id: company.id, created_by_user_id: user.id,
      name: "C", campaign_type: "drip", from_identity_type: "User",
      from_identity_id: user.id, throttle_per_day: 100
    )
  end

  it "validates wait_hours <= 23" do
    s = campaign.campaign_steps.build(position: 0, wait_hours: 24)
    expect(s).not_to be_valid
    expect(s.errors[:wait_hours]).to be_present
  end

  it "validates position >= 0" do
    s = campaign.campaign_steps.build(position: -1)
    expect(s).not_to be_valid
    expect(s.errors[:position]).to be_present
  end

  describe "footer_unsubscribe auto-injection" do
    it "appends a footer_unsubscribe block when missing" do
      step = campaign.campaign_steps.create!(position: 0, body_blocks: [{ "type" => "text", "html" => "hi" }])
      step.reload
      expect(step.body_blocks.last["type"]).to eq("footer_unsubscribe")
    end

    it "does not duplicate the footer when already present" do
      step = campaign.campaign_steps.create!(position: 0, body_blocks: [
        { "type" => "text", "html" => "hi" },
        { "type" => "footer_unsubscribe" }
      ])
      step.reload
      footer_count = step.body_blocks.count { |b| b["type"] == "footer_unsubscribe" }
      expect(footer_count).to eq(1)
    end

    it "does not inject when body_blocks is empty (nothing to render)" do
      step = campaign.campaign_steps.create!(position: 0, body_blocks: [])
      step.reload
      expect(step.body_blocks).to eq([])
    end
  end
end
