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
end
