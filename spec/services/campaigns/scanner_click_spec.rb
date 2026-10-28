# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::ScannerClick do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C', campaign_type: 'blast',
                     from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
  end
  let(:step) { campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ 'type' => 'text', 'html' => 'x' }]) }
  let(:sent_at) { Time.zone.parse('2026-10-28 19:07:00') }

  def clicked_send(*offsets)
    lead = Lead.create!(company: company, first_name: 'B', last_name: SecureRandom.hex(2), email: "b-#{SecureRandom.hex(4)}@example.com")
    enrollment = CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                                            recipient_id: lead.id, email_address_snapshot: lead.email)
    cs = CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                              campaign_enrollment_id: enrollment.id, sent_at: sent_at,
                              clicked_at: sent_at + offsets.min, click_count: offsets.size)
    offsets.each_with_index do |o, i|
      CampaignLinkToken.create!(campaign_id: campaign.id, campaign_send_id: cs.id, target_url: "https://example.com/#{i}",
                                click_count: 1, first_clicked_at: sent_at + o, last_clicked_at: sent_at + o)
    end
    cs
  end

  describe '.reclassify!' do
    it 'clears sends whose clicks were all one burst and leaves the rest' do
      burst = clicked_send(20, 20, 21, 21)
      single = clicked_send(35)
      spread = clicked_send(26, 39)

      expect(described_class.reclassify!(CampaignSend.where(campaign_id: campaign.id))).to eq(1)

      expect(burst.reload.clicked_at).to be_nil
      expect(burst.metadata['scanner_clicks']).to eq(4)
      expect(single.reload.clicked_at).to be_present
      expect(spread.reload.clicked_at).to be_present
    end
  end
end
