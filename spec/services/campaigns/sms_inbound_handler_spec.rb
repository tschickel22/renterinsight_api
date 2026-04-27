# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::SmsInboundHandler, type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "T", last_name: "U", password: "Pass1234!", company_id: company.id) }
  let(:source)  { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
  let(:lead) do
    Lead.create!(company: company, source: source,
                 first_name: "B", last_name: "1",
                 email: "b-#{SecureRandom.hex(4)}@example.com",
                 phone: "5551234567", opt_in_sms: true)
  end
  let(:sms_campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "SMS-#{SecureRandom.hex(4)}",
                     campaign_type: "blast", channel: "sms",
                     from_identity_type: "User", from_identity_id: user.id, throttle_per_day: 100)
  end
  let!(:twilio_acct) do
    TwilioAccount.create!(company_id: company.id, phone_number: "+15558889999",
                          phone_number_sid: "PN1", status: "active")
  end
  let!(:enrollment) do
    CampaignEnrollment.create!(
      company_id: company.id, campaign_id: sms_campaign.id,
      recipient_type: "Lead", recipient_id: lead.id,
      sms_phone_snapshot: "+15551234567",
      status: "active"
    )
  end

  describe "#classify_keyword" do
    it "recognizes STOP keywords (case-insensitive, leading)" do
      %w[STOP stop Stop UNSUBSCRIBE Cancel quit END opt-out OPTOUT].each do |w|
        expect(described_class.classify_keyword(w)).to eq(:stop)
      end
    end

    it "recognizes HELP keywords" do
      expect(described_class.classify_keyword("HELP")).to eq(:help)
      expect(described_class.classify_keyword("Info please")).to eq(:help)
    end

    it "recognizes START keywords" do
      expect(described_class.classify_keyword("START")).to eq(:start)
      expect(described_class.classify_keyword("yes")).to eq(:start)
    end

    it "returns nil for non-keyword bodies" do
      expect(described_class.classify_keyword("hi how are you")).to be_nil
      expect(described_class.classify_keyword(nil)).to be_nil
      expect(described_class.classify_keyword("")).to be_nil
    end
  end

  describe ".process for STOP" do
    it "creates suppression and unsubscribes enrollments" do
      expect {
        result = described_class.process(from_phone: "+15551234567", body: "STOP", to_phone: "+15558889999")
        expect(result.handled).to be(true)
        expect(result.event_type).to eq('sms_stop')
        expect(result.reply_body).to include("unsubscribed")
      }.to change { CampaignSuppression.where(company_id: company.id, phone_number: "+15551234567").count }.by(1)

      enrollment.reload
      expect(enrollment.status).to eq("unsubscribed")
      expect(enrollment.unsubscribed_at).to be_present

      events = CampaignEvent.where(campaign_id: sms_campaign.id, event_type: 'sms_stop')
      expect(events.count).to eq(1)
    end

    it "is idempotent if STOP is sent twice" do
      described_class.process(from_phone: "+15551234567", body: "STOP", to_phone: "+15558889999")
      expect {
        described_class.process(from_phone: "+15551234567", body: "STOP", to_phone: "+15558889999")
      }.not_to change { CampaignSuppression.where(company_id: company.id, phone_number: "+15551234567").count }
    end
  end

  describe ".process for HELP" do
    it "returns reply with company info, no suppression" do
      result = described_class.process(from_phone: "+15551234567", body: "HELP", to_phone: "+15558889999")
      expect(result.handled).to be(true)
      expect(result.event_type).to eq('sms_help')
      expect(result.reply_body).to include("Reply STOP")
      expect(CampaignSuppression.where(company_id: company.id, phone_number: "+15551234567").count).to eq(0)
    end
  end

  describe ".process for START" do
    it "removes any prior sms_stop suppression for this phone" do
      CampaignSuppression.create!(company_id: company.id, phone_number: "+15551234567", reason: "sms_stop")
      expect {
        result = described_class.process(from_phone: "+15551234567", body: "START", to_phone: "+15558889999")
        expect(result.handled).to be(true)
        expect(result.event_type).to eq('sms_start')
      }.to change { CampaignSuppression.where(company_id: company.id, phone_number: "+15551234567").count }.from(1).to(0)
    end
  end

  describe ".process — fall-through cases" do
    it "returns handled=false when body is not a keyword" do
      result = described_class.process(from_phone: "+15551234567", body: "Cool, when can we meet?", to_phone: "+15558889999")
      expect(result.handled).to be(false)
    end

    it "returns handled=false when To number does not match any TwilioAccount" do
      result = described_class.process(from_phone: "+15551234567", body: "STOP", to_phone: "+15550000000")
      expect(result.handled).to be(false)
    end

    it "returns handled=false when From number was never a campaign recipient" do
      # Different from_phone, no enrollment exists
      result = described_class.process(from_phone: "+15559998888", body: "STOP", to_phone: "+15558889999")
      expect(result.handled).to be(false)
    end
  end
end
