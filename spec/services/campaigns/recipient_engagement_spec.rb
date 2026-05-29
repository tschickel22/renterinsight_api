# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::RecipientEngagement do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:user) { User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "Rep", last_name: "One", password: "Pass1234!", company_id: company.id) }
  let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
  let(:lead) { Lead.create!(company: company, source: source, first_name: "Hot", last_name: "Lead", email: "hot-#{SecureRandom.hex(4)}@example.com", phone: "555-1212", owner_id: user.id) }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "C",
                     campaign_type: "blast", from_identity_type: "User", from_identity_id: user.id, throttle_per_day: 100)
  end
  let(:step) { campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ "type" => "text", "html" => "x" }]) }
  let(:enrollment) { CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: "Lead", recipient_id: lead.id, email_address_snapshot: lead.email) }
  let!(:send_rec) do
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                         campaign_enrollment_id: enrollment.id,
                         sent_at: 2.hours.ago, opened_at: 1.hour.ago, open_count: 2,
                         clicked_at: 30.minutes.ago, click_count: 1)
  end

  def result
    described_class.new(campaign: campaign).call
  end

  it 'returns the recipient with aggregated opens/clicks and contact info' do
    item = result[:items].first
    expect(item[:recipient_id]).to eq(lead.id)
    expect(item[:name]).to eq("Hot Lead")
    expect(item[:phone]).to eq("555-1212")
    expect(item[:opens]).to eq(2)
    expect(item[:clicks]).to eq(1)
    expect(item[:owner_name]).to eq("Rep One")
    expect(item[:last_engagement_at]).to be_present
    expect(item[:link]).to eq("/crm/leads/#{lead.id}")
  end

  it 'reports campaign-level stats' do
    expect(result[:meta][:stats]).to include(recipients: 1, opened: 1, clicked: 1)
  end

  it 'lists the links the recipient clicked' do
    token = CampaignLinkToken.create!(campaign_id: campaign.id, campaign_send_id: send_rec.id, target_url: "https://example.com/pricing")
    token.record_click!

    links = result[:items].first[:clicked_links]
    expect(links.map { |l| l[:url] }).to include("https://example.com/pricing")
    expect(links.first[:clicks]).to be >= 1
  end

  it 'engaged_only filters out recipients with no opens or clicks' do
    cold = Lead.create!(company: company, source: source, first_name: "Cold", last_name: "Lead", email: "cold-#{SecureRandom.hex(4)}@example.com", owner_id: user.id)
    cold_enr = CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: "Lead", recipient_id: cold.id, email_address_snapshot: cold.email)
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                         campaign_enrollment_id: cold_enr.id, sent_at: 1.hour.ago)

    all_ids     = described_class.new(campaign: campaign).call[:items].map { |i| i[:recipient_id] }
    engaged_ids = described_class.new(campaign: campaign, engaged_only: true).call[:items].map { |i| i[:recipient_id] }

    expect(all_ids).to include(lead.id, cold.id)
    expect(engaged_ids).to include(lead.id)
    expect(engaged_ids).not_to include(cold.id)
  end

  it 'excludes test sends from the engagement list' do
    test_enr = CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: "User",
                                          recipient_id: user.id, email_address_snapshot: user.email,
                                          metadata: { 'test_send' => 'true' })
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                         campaign_enrollment_id: test_enr.id, sent_at: 1.hour.ago, opened_at: 1.hour.ago, open_count: 5)

    ids = result[:items].map { |i| i[:enrollment_id] }
    expect(ids).not_to include(test_enr.id)
  end
end
