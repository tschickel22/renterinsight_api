# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CampaignSend, type: :model do
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
  let(:communication) do
    Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'outbound',
                          subject: 'S', body: 'B', from_address: 'sender@example.com',
                          to_address: lead.email, status: 'sent')
  end
  let(:cs) do
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                         campaign_enrollment_id: enr.id, communication_id: communication.id)
  end

  describe '.record_open_for_communication' do
    it 'stamps opened_at once and increments open_count on each open' do
      cs # create
      described_class.record_open_for_communication(communication.id)
      cs.reload
      first_opened = cs.opened_at
      expect(first_opened).to be_present
      expect(cs.open_count).to eq(1)

      described_class.record_open_for_communication(communication.id)
      cs.reload
      expect(cs.opened_at).to eq(first_opened) # not re-stamped
      expect(cs.open_count).to eq(2)
    end

    it 'is a no-op for blank or unknown communication_id' do
      cs
      expect { described_class.record_open_for_communication(nil) }.not_to raise_error
      expect { described_class.record_open_for_communication(0) }.not_to raise_error
      cs.reload
      expect(cs.open_count).to eq(0)
    end
  end

  describe '.record_click_for_communication' do
    it 'stamps clicked_at once and increments click_count on each click' do
      cs
      described_class.record_click_for_communication(communication.id)
      cs.reload
      first_clicked = cs.clicked_at
      expect(first_clicked).to be_present
      expect(cs.click_count).to eq(1)

      described_class.record_click_for_communication(communication.id)
      cs.reload
      expect(cs.clicked_at).to eq(first_clicked)
      expect(cs.click_count).to eq(2)
    end

    it 'treats a click as an implied open (open pixels are often blocked by mail clients)' do
      cs
      expect(cs.opened_at).to be_nil
      described_class.record_click_for_communication(communication.id)
      cs.reload
      expect(cs.opened_at).to be_present
      expect(cs.open_count).to be >= 1
    end

    it 'does not overwrite a real opened_at when a click arrives later' do
      cs
      described_class.record_open_for_communication(communication.id)
      cs.reload
      real_open = cs.opened_at
      described_class.record_click_for_communication(communication.id)
      cs.reload
      expect(cs.opened_at).to eq(real_open)
    end
  end
end
