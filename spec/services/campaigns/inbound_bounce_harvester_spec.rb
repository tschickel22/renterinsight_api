# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::InboundBounceHarvester do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "T", last_name: "U",
                 password: "Pass1234!", company_id: company.id, role: "platform_admin")
  end
  let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
  let(:lead) { Lead.create!(company: company, source: source, first_name: "B", email: "buyer-#{SecureRandom.hex(4)}@example.com") }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "C",
      campaign_type: "blast", from_identity_type: "User", from_identity_id: user.id, throttle_per_day: 100)
  end
  let(:step) { campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ "type" => "text", "html" => "x" }]) }
  let(:enrollment) do
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: "Lead",
                               recipient_id: lead.id, email_address_snapshot: lead.email)
  end
  let!(:send_record) do
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                         campaign_enrollment_id: enrollment.id, sent_at: 1.hour.ago)
  end

  describe ".resolve_token" do
    it "extracts the campaign token from the reply+ address in the wrapped original" do
      parsed = { headers: "To: reply+campaign-#{send_record.id}@mail.renterinsight.com", subject: "Undeliverable", body_text: "" }
      expect(described_class.resolve_token(parsed)).to eq("campaign-#{send_record.id}")
    end

    it "falls back to the most recent send to the failed recipient when no token present" do
      parsed = { headers: "", subject: "Delivery Status Notification (Failure)",
                 body_text: "Your message to #{lead.email} could not be delivered.", to: "" }
      expect(described_class.resolve_token(parsed, company_id: company.id)).to eq("campaign-#{send_record.id}")
    end

    it "ignores our own reply+ / infra addresses in the recipient fallback" do
      parsed = { headers: "", subject: "x", body_text: "noise reply+campaign-#{send_record.id}@mail.renterinsight.com",
                 to: "" }
      # reply+ token wins via the primary path, not the address fallback
      expect(described_class.resolve_token(parsed, company_id: company.id)).to eq("campaign-#{send_record.id}")
    end
  end

  describe ".dispatch_message" do
    it "stamps bounced_at and suppresses the address on a hard-bounce NDR" do
      parsed = {
        headers: "To: reply+campaign-#{send_record.id}@mail.renterinsight.com\nContent-Type: multipart/report; report-type=delivery-status",
        from: "postmaster@outbound.protection.outlook.com",
        subject: "Undeliverable: DealerTide 5-Email Prospect Series",
        body_text: "550 5.1.1 The email account that you tried to reach does not exist. recipient address rejected",
        content_type: "multipart/report; report-type=delivery-status"
      }

      expect {
        outcome = described_class.dispatch_message(parsed, company_id: company.id)
        expect(outcome).to eq(:bounce_hard)
      }.to change { CampaignSuppression.where(company_id: company.id).count }.by(1)

      send_record.reload
      expect(send_record.bounced_at).to be_present
      expect(send_record.bounce_type).to eq("hard")
    end

    it "handles an out-of-office auto-reply without marking a bounce" do
      parsed = {
        headers: "To: reply+campaign-#{send_record.id}@mail.renterinsight.com\nAuto-Submitted: auto-replied",
        from: lead.email,
        subject: "Automatic reply: DealerTide 5-Email Prospect Series",
        body_text: "I am currently out of office and will return Monday.",
        content_type: "text/plain"
      }
      outcome = described_class.dispatch_message(parsed, company_id: company.id)
      expect(outcome).to eq(:auto_reply)
      send_record.reload
      expect(send_record.bounced_at).to be_nil
    end

    it "ignores a genuine human reply (no token action)" do
      parsed = {
        headers: "To: reply+campaign-#{send_record.id}@mail.renterinsight.com",
        from: lead.email,
        subject: "Re: your homes",
        body_text: "Yes, I'd love to schedule a tour this weekend!",
        content_type: "text/plain"
      }
      expect(described_class.dispatch_message(parsed, company_id: company.id)).to be_nil
      send_record.reload
      expect(send_record.bounced_at).to be_nil
    end
  end
end
