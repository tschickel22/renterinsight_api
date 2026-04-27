# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CampaignLinkToken, type: :model do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:user) { User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "T", last_name: "U", password: "Pass1234!", company_id: company.id) }
  let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
  let(:lead) { Lead.create!(company: company, source: source, first_name: "B", last_name: "1", email: "b-#{SecureRandom.hex(4)}@example.com") }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "C",
                     campaign_type: "blast", from_identity_type: "User",
                     from_identity_id: user.id, throttle_per_day: 100)
  end
  let(:step) { campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ "type" => "text", "html" => "x" }]) }
  let(:enr) { CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: "Lead", recipient_id: lead.id, email_address_snapshot: lead.email) }
  let(:cs) { CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id, campaign_enrollment_id: enr.id) }

  it "auto-generates a unique token on create" do
    t1 = CampaignLinkToken.create!(campaign_id: campaign.id, campaign_send_id: cs.id, target_url: "https://example.com/a")
    t2 = CampaignLinkToken.create!(campaign_id: campaign.id, campaign_send_id: cs.id, target_url: "https://example.com/b")
    expect(t1.token).to be_present
    expect(t2.token).to be_present
    expect(t1.token).not_to eq(t2.token)
  end

  it "increments click_count and stamps timestamps via #record_click!" do
    t = CampaignLinkToken.create!(campaign_id: campaign.id, campaign_send_id: cs.id, target_url: "https://example.com")
    t.record_click!
    t.reload
    expect(t.click_count).to eq(1)
    expect(t.first_clicked_at).to be_present
    expect(t.last_clicked_at).to be_present
  end
end
