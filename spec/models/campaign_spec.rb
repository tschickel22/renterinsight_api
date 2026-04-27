# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaign, type: :model do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:user)    { User.create!(email: "user-#{SecureRandom.hex(4)}@example.com", first_name: "Test", last_name: "User", password: "Pass1234!", company_id: company.id) }

  let(:base_attrs) do
    {
      company_id: company.id,
      created_by_user_id: user.id,
      name: "Spring Promo",
      campaign_type: "blast",
      audience_mode: "static",
      from_identity_type: "User",
      from_identity_id: user.id,
      throttle_per_day: 500,
      status: "draft"
    }
  end

  describe "validations" do
    it "requires name, status, campaign_type, from_identity_type" do
      c = Campaign.new
      expect(c).not_to be_valid
      expect(c.errors[:name]).to be_present
    end

    it "validates status inclusion" do
      c = Campaign.new(base_attrs.merge(status: "bogus"))
      expect(c).not_to be_valid
      expect(c.errors[:status]).to include(a_string_matching(/not included/i))
    end

    it "validates campaign_type inclusion" do
      c = Campaign.new(base_attrs.merge(campaign_type: "rocket"))
      expect(c).not_to be_valid
      expect(c.errors[:campaign_type]).to be_present
    end

    it "accepts only User/Location/Company for from_identity_type" do
      Campaign::IDENTITY_TYPES.each do |t|
        c = Campaign.new(base_attrs.merge(from_identity_type: t))
        c.valid?
        expect(c.errors[:from_identity_type]).to be_empty
      end
    end

    it "validates throttle_per_day > 0" do
      c = Campaign.new(base_attrs.merge(throttle_per_day: 0))
      expect(c).not_to be_valid
      expect(c.errors[:throttle_per_day]).to be_present
    end
  end

  describe "scopes" do
    let!(:c_active) { Campaign.create!(base_attrs.merge(name: "active-1")) }
    let!(:c_deleted) { Campaign.create!(base_attrs.merge(name: "del-1", is_deleted: true)) }

    it "active scope excludes is_deleted" do
      expect(Campaign.active).to include(c_active)
      expect(Campaign.active).not_to include(c_deleted)
    end

    it "for_company scopes by company_id" do
      other_company = Company.create!(name: "Other")
      other_user = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", first_name: "O", last_name: "U", password: "Pass1234!", company_id: other_company.id)
      Campaign.create!(base_attrs.merge(company_id: other_company.id, created_by_user_id: other_user.id, from_identity_id: other_user.id, name: "elsewhere"))
      expect(Campaign.for_company(company.id)).to include(c_active)
      expect(Campaign.for_company(company.id).map(&:company_id).uniq).to eq([company.id])
    end
  end

  describe "#resolve_email_connection" do
    it "returns nil when no UserEmailConnection exists for the identity" do
      c = Campaign.create!(base_attrs)
      expect(c.resolve_email_connection).to be_nil
    end

    it "NEVER falls through to a platform default — strictly returns nil for missing identity" do
      c = Campaign.create!(base_attrs.merge(from_identity_type: "Company", from_identity_id: company.id))
      expect(c.resolve_email_connection).to be_nil
    end

    it "returns the active UserEmailConnection when one exists" do
      conn = UserEmailConnection.create!(
        user_id: user.id,
        company_id: company.id,
        provider: "oauth_gmail",
        email_address: "u@example.com",
        is_active: true,
        oauth_token_encrypted: "tok",
        oauth_refresh_token_encrypted: "ref"
      )
      c = Campaign.create!(base_attrs)
      expect(c.resolve_email_connection).to eq(conn)
    end
  end

  describe "#can_start?" do
    let(:campaign) { Campaign.create!(base_attrs) }

    it "is false when status is not draft" do
      campaign.update!(status: "running")
      expect(campaign.can_start?).to be(false)
    end

    it "is false with no active steps" do
      expect(campaign.can_start?).to be(false)
    end

    it "is false with no audience even if steps exist" do
      campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ "type" => "text", "html" => "hi" }])
      expect(campaign.can_start?).to be(false)
    end

    it "is false when email connection cannot be resolved" do
      campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ "type" => "text", "html" => "hi" }])
      campaign.create_campaign_audience!(source_type: "Lead")
      expect(campaign.can_start?).to be(false)
    end

    it "is true with all preconditions met" do
      UserEmailConnection.create!(user_id: user.id, company_id: company.id, provider: "oauth_gmail", email_address: "u@e.com", is_active: true, oauth_token_encrypted: "x", oauth_refresh_token_encrypted: "y")
      campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ "type" => "text", "html" => "hi" }])
      campaign.create_campaign_audience!(source_type: "Lead")
      expect(campaign.can_start?).to be(true)
    end
  end
end
