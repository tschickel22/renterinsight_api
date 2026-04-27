# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CampaignSuppression, type: :model do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }

  it "downcases email on save" do
    s = CampaignSuppression.create!(company_id: company.id, email_address: "Foo@Bar.COM ", reason: "manual")
    expect(s.email_address).to eq("foo@bar.com")
  end

  it "auto-stamps suppressed_at" do
    s = CampaignSuppression.create!(company_id: company.id, email_address: "x@y.com", reason: "manual")
    expect(s.suppressed_at).to be_present
  end

  it "validates reason inclusion" do
    s = CampaignSuppression.new(company_id: company.id, email_address: "x@y.com", reason: "bogus")
    expect(s).not_to be_valid
    expect(s.errors[:reason]).to be_present
  end

  it "enforces uniqueness on (company_id, email_address) case-insensitive" do
    CampaignSuppression.create!(company_id: company.id, email_address: "x@Y.com", reason: "unsubscribe")
    dup = CampaignSuppression.new(company_id: company.id, email_address: "X@y.com", reason: "manual")
    expect(dup).not_to be_valid
  end

  describe ".suppressed?" do
    it "returns true when email is on the list (case-insensitive)" do
      CampaignSuppression.create!(company_id: company.id, email_address: "Foo@Bar.com", reason: "unsubscribe")
      expect(described_class.suppressed?(company.id, "FOO@bar.COM")).to be(true)
    end

    it "returns false when not on the list" do
      expect(described_class.suppressed?(company.id, "missing@example.com")).to be(false)
    end

    it "returns false for blank email" do
      expect(described_class.suppressed?(company.id, nil)).to be(false)
      expect(described_class.suppressed?(company.id, "")).to be(false)
    end
  end

  # ============================================================
  # Phase A.5 — phone-channel suppressions
  # ============================================================
  describe "phone-only suppressions" do
    it "is valid with only phone_number" do
      s = CampaignSuppression.new(company_id: company.id, phone_number: "5551234567", reason: "sms_stop")
      expect(s).to be_valid
    end

    it "is invalid when both email and phone are present" do
      s = CampaignSuppression.new(company_id: company.id, email_address: "x@y.com", phone_number: "5551234567", reason: "manual")
      expect(s).not_to be_valid
      expect(s.errors[:base]).to include(/either.+OR.+not both/i)
    end

    it "is invalid when neither email nor phone is present" do
      s = CampaignSuppression.new(company_id: company.id, reason: "manual")
      expect(s).not_to be_valid
      expect(s.errors[:base]).to include(/Either.+must be present/i)
    end

    it "normalizes phone numbers to E.164 format on save" do
      s = CampaignSuppression.create!(company_id: company.id, phone_number: "(555) 123-4567", reason: "sms_stop")
      expect(s.phone_number).to eq("+15551234567")
    end

    it "enforces uniqueness on (company_id, phone_number) after normalization" do
      CampaignSuppression.create!(company_id: company.id, phone_number: "5551234567", reason: "sms_stop")
      dup = CampaignSuppression.new(company_id: company.id, phone_number: "+1 (555) 123-4567", reason: "manual")
      expect(dup).not_to be_valid
    end
  end

  describe ".suppressed? for phone numbers" do
    it "returns true when phone is on the list (after normalization)" do
      CampaignSuppression.create!(company_id: company.id, phone_number: "+15551234567", reason: "sms_stop")
      expect(described_class.suppressed?(company.id, "5551234567")).to be(true)
      expect(described_class.suppressed?(company.id, "(555) 123-4567")).to be(true)
    end

    it "returns false when phone is not on the list" do
      expect(described_class.suppressed?(company.id, "5550000000")).to be(false)
    end

    it "discriminates email vs phone by '@' presence" do
      CampaignSuppression.create!(company_id: company.id, email_address: "match@test.com", reason: "manual")
      CampaignSuppression.create!(company_id: company.id, phone_number: "+15550000000", reason: "sms_stop")
      expect(described_class.suppressed?(company.id, "match@test.com")).to be(true)
      expect(described_class.suppressed?(company.id, "5550000000")).to be(true)
    end
  end

  describe "REASONS includes sms_stop" do
    it "accepts sms_stop as a valid reason" do
      s = CampaignSuppression.new(company_id: company.id, phone_number: "+15551234567", reason: "sms_stop")
      expect(s).to be_valid
    end
  end
end
