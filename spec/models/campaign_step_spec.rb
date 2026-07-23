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

    it "does NOT inject a footer block for a raw_html step (it manages its own unsubscribe)" do
      step = campaign.campaign_steps.create!(position: 0, body_blocks: [
        { "type" => "raw_html", "html" => "<html><body>hi</body></html>", "append_unsubscribe" => true }
      ])
      step.reload
      expect(step.raw_html_step?).to be(true)
      expect(step.body_blocks.map { |b| b["type"] }).to eq(["raw_html"])
    end
  end

  # ============================================================
  # Phase A.5 — SMS channel
  # ============================================================
  describe "channel inheritance" do
    it "inherits channel from the parent campaign on save" do
      sms_campaign = Campaign.create!(
        company_id: company.id, created_by_user_id: user.id, name: "SMS",
        campaign_type: "blast", channel: "sms",
        from_identity_type: "User", from_identity_id: user.id, throttle_per_day: 100
      )
      step = sms_campaign.campaign_steps.create!(position: 0, sms_body: "Hi {{first_name}}")
      expect(step.channel).to eq("sms")
    end

    # Phase E — mixed-channel drips
    it "defaults to the campaign's channel when the step's channel is blank" do
      step = campaign.campaign_steps.create!(position: 0, body_blocks: [{ "type" => "text", "html" => "hi" }])
      expect(step.channel).to eq(campaign.channel)
    end

    it "does NOT overwrite an explicitly-set per-step channel that differs from the campaign" do
      # campaign.channel == 'email' (the default). Set step.channel = 'sms' explicitly.
      step = campaign.campaign_steps.create!(position: 0, channel: "sms", sms_body: "Hi {{first_name}}")
      step.reload
      expect(step.channel).to eq("sms")
      expect(campaign.channel).to eq("email")
    end

    it "allows an SMS step inside an email campaign and persists the override" do
      step = campaign.campaign_steps.create!(position: 1, channel: "sms", sms_body: "Hi {{first_name}}")
      # Re-save to ensure the before_validation callback doesn't clobber it on subsequent saves.
      step.update!(sms_body: "Hi {{first_name}}, take a look")
      step.reload
      expect(step.channel).to eq("sms")
    end
  end

  describe "SMS body validations" do
    let(:sms_campaign) do
      Campaign.create!(
        company_id: company.id, created_by_user_id: user.id, name: "SMS",
        campaign_type: "blast", channel: "sms",
        from_identity_type: "User", from_identity_id: user.id, throttle_per_day: 100
      )
    end

    it "requires sms_body when channel is sms" do
      step = sms_campaign.campaign_steps.build(position: 0, sms_body: nil)
      expect(step).not_to be_valid
      expect(step.errors[:sms_body]).to include(/must be present/i)
    end

    it "rejects sms_body longer than SMS_MAX_LENGTH" do
      step = sms_campaign.campaign_steps.build(position: 0, sms_body: "a" * (CampaignStep::SMS_MAX_LENGTH + 5))
      expect(step).not_to be_valid
      expect(step.errors[:sms_body]).to include(/must be #{CampaignStep::SMS_MAX_LENGTH}/)
    end

    it "rejects inventory_block_config when channel is sms" do
      step = sms_campaign.campaign_steps.build(
        position: 0, sms_body: "Hi", inventory_block_config: { "mode" => "segment_based" }
      )
      expect(step).not_to be_valid
      expect(step.errors[:inventory_block_config]).to be_present
    end
  end

  describe "ensure_sms_stop_footer" do
    let(:sms_campaign) do
      Campaign.create!(
        company_id: company.id, created_by_user_id: user.id, name: "SMS",
        campaign_type: "blast", channel: "sms",
        from_identity_type: "User", from_identity_id: user.id, throttle_per_day: 100
      )
    end

    it "auto-appends 'Reply STOP to unsubscribe' when missing" do
      step = sms_campaign.campaign_steps.create!(position: 0, sms_body: "Hi there")
      step.reload
      expect(step.sms_body).to include("Reply STOP to unsubscribe")
    end

    it "does NOT duplicate the footer when STOP language already present" do
      step = sms_campaign.campaign_steps.create!(position: 0, sms_body: "Hi there. Reply STOP to opt out.")
      step.reload
      stop_count = step.sms_body.scan(/Reply STOP/i).length
      expect(stop_count).to eq(1)
    end

    it "rejects bodies that pack the SMS too tight to fit the footer" do
      tight_body = "a" * (CampaignStep::SMS_MAX_LENGTH - 5)
      step = sms_campaign.campaign_steps.build(position: 0, sms_body: tight_body)
      step.valid?
      step.save # triggers ensure_sms_stop_footer
      expect(step.errors[:sms_body]).to include(/leaves no room/i)
    end
  end
end
