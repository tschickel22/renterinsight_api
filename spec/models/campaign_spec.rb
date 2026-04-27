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

  # ============================================================
  # Phase A.5 — SMS channel
  # ============================================================
  describe "channel" do
    it "validates inclusion in CHANNELS" do
      c = Campaign.new(base_attrs.merge(channel: "fax"))
      expect(c).not_to be_valid
      expect(c.errors[:channel]).to be_present
    end

    it "defaults to email for new campaigns when not specified" do
      c = Campaign.create!(base_attrs)
      expect(c.channel).to eq("email")
      expect(c.email_channel?).to be(true)
      expect(c.sms_channel?).to be(false)
    end

    it "supports sms channel" do
      c = Campaign.create!(base_attrs.merge(channel: "sms"))
      expect(c.sms_channel?).to be(true)
    end
  end

  describe "enforce_sms_identity_constraints callback" do
    it "forces from_identity_type='Company' and from_identity_id=company_id when channel=sms" do
      c = Campaign.create!(base_attrs.merge(channel: "sms", from_identity_type: "User", from_identity_id: user.id))
      expect(c.from_identity_type).to eq("Company")
      expect(c.from_identity_id).to eq(company.id)
    end

    it "leaves identity untouched when channel=email" do
      c = Campaign.create!(base_attrs)
      expect(c.from_identity_type).to eq("User")
      expect(c.from_identity_id).to eq(user.id)
    end
  end

  describe "#resolve_sms_sender" do
    it "returns nil when channel is email" do
      c = Campaign.create!(base_attrs)
      TwilioAccount.create!(company_id: company.id, phone_number: "+15551112222", phone_number_sid: "PN1", status: "active")
      expect(c.resolve_sms_sender).to be_nil
    end

    it "returns nil when no active TwilioAccount exists for the company" do
      c = Campaign.create!(base_attrs.merge(channel: "sms"))
      expect(c.resolve_sms_sender).to be_nil
    end

    it "returns the company-wide TwilioAccount when present (no location)" do
      acct = TwilioAccount.create!(company_id: company.id, phone_number: "+15551112222", phone_number_sid: "PN1", status: "active")
      c = Campaign.create!(base_attrs.merge(channel: "sms"))
      expect(c.resolve_sms_sender).to eq(acct)
    end

    it "prefers the location-scoped TwilioAccount when campaign has location_id" do
      location = company.locations.create!(name: "Loc A")
      company_acct  = TwilioAccount.create!(company_id: company.id, phone_number: "+15551112222", phone_number_sid: "PN1", status: "active")
      location_acct = TwilioAccount.create!(company_id: company.id, location_id: location.id, phone_number: "+15553334444", phone_number_sid: "PN2", status: "active")
      c = Campaign.create!(base_attrs.merge(channel: "sms", location_id: location.id))
      expect(c.resolve_sms_sender).to eq(location_acct)
      # Without location_id, falls back to company-wide
      c2 = Campaign.create!(base_attrs.merge(channel: "sms", name: "S2"))
      expect(c2.resolve_sms_sender).to eq(company_acct)
    end

    it "NEVER returns a TwilioAccount belonging to a different company" do
      other_company = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      TwilioAccount.create!(company_id: other_company.id, phone_number: "+15559998888", phone_number_sid: "PN9", status: "active")
      c = Campaign.create!(base_attrs.merge(channel: "sms"))
      expect(c.resolve_sms_sender).to be_nil
    end

    it "NEVER falls back to a master/platform number when company has none" do
      # Even with the platform's TWILIO_PHONE_NUMBER env set, resolve_sms_sender
      # only looks at the TwilioAccount table — never master.
      c = Campaign.create!(base_attrs.merge(channel: "sms"))
      expect(c.resolve_sms_sender).to be_nil
    end
  end

  # ============================================================
  # Phase E — mixed-channel drips
  # ============================================================
  describe "#mixed_channel?" do
    let(:campaign) { Campaign.create!(base_attrs) }

    it "returns false when all steps share the campaign channel" do
      campaign.campaign_steps.create!(position: 0, body_blocks: [{ "type" => "text", "html" => "hi" }])
      campaign.campaign_steps.create!(position: 1, body_blocks: [{ "type" => "text", "html" => "again" }])
      expect(campaign.mixed_channel?).to be(false)
    end

    it "returns true when steps mix email and sms channels" do
      campaign.campaign_steps.create!(position: 0, channel: "email", body_blocks: [{ "type" => "text", "html" => "hi" }])
      campaign.campaign_steps.create!(position: 1, channel: "sms", sms_body: "Hi {{first_name}}")
      expect(campaign.mixed_channel?).to be(true)
    end
  end

  describe "#can_start? for mixed-channel campaigns" do
    let(:campaign) { Campaign.create!(base_attrs) }

    before do
      campaign.campaign_steps.create!(position: 0, channel: "email", body_blocks: [{ "type" => "text", "html" => "hi" }])
      campaign.campaign_steps.create!(position: 1, channel: "sms", sms_body: "Hi {{first_name}}")
      campaign.create_campaign_audience!(source_type: "Lead")
    end

    it "is false when no email connection is resolvable" do
      allow(campaign).to receive(:resolve_email_connection_for_step).and_return(nil)
      allow(campaign).to receive(:resolve_sms_sender_for_step).and_return(double("twilio"))
      expect(campaign.can_start?).to be(false)
    end

    it "is false when no SMS sender is resolvable" do
      allow(campaign).to receive(:resolve_email_connection_for_step).and_return(double("conn"))
      allow(campaign).to receive(:resolve_sms_sender_for_step).and_return(nil)
      expect(campaign.can_start?).to be(false)
    end

    it "is true when both email connection and SMS sender are resolvable" do
      allow(campaign).to receive(:resolve_email_connection_for_step).and_return(double("conn"))
      allow(campaign).to receive(:resolve_sms_sender_for_step).and_return(double("twilio"))
      expect(campaign.can_start?).to be(true)
    end
  end

  describe "#can_start? for SMS campaigns" do
    let(:campaign) { Campaign.create!(base_attrs.merge(channel: "sms")) }

    it "is false when there is no active TwilioAccount" do
      campaign.campaign_steps.create!(position: 0, is_active: true, sms_body: "hi {{first_name}}")
      campaign.create_campaign_audience!(source_type: "Lead")
      expect(campaign.can_start?).to be(false)
    end

    it "is true when TwilioAccount + steps + audience all present" do
      TwilioAccount.create!(company_id: company.id, phone_number: "+15551112222", phone_number_sid: "PN1", status: "active")
      campaign.campaign_steps.create!(position: 0, is_active: true, sms_body: "hi {{first_name}}")
      campaign.create_campaign_audience!(source_type: "Lead")
      expect(campaign.can_start?).to be(true)
    end

    it "does NOT require an email connection for SMS campaigns" do
      TwilioAccount.create!(company_id: company.id, phone_number: "+15551112222", phone_number_sid: "PN1", status: "active")
      campaign.campaign_steps.create!(position: 0, is_active: true, sms_body: "hi {{first_name}}")
      campaign.create_campaign_audience!(source_type: "Lead")
      expect(UserEmailConnection.where(user_id: user.id).count).to eq(0)
      expect(campaign.can_start?).to be(true)
    end
  end

  # ============================================================
  # Phase E patch — step-level resolvers (mixed-channel drips)
  # ============================================================
  describe "#resolve_email_connection_for_step" do
    it "returns the active UserEmailConnection even when campaign.channel is sms" do
      conn = UserEmailConnection.create!(
        user_id: user.id,
        company_id: company.id,
        provider: "oauth_gmail",
        email_address: "rep@example.com",
        is_active: true,
        oauth_token_encrypted: "tok",
        oauth_refresh_token_encrypted: "ref"
      )

      # Build an SMS campaign, then bypass the SMS-identity callback so we can
      # verify the step-level resolver still finds the User-bound connection.
      campaign = Campaign.new(base_attrs.merge(channel: "sms"))
      campaign.save(validate: false)
      campaign.update_columns(from_identity_type: "User", from_identity_id: user.id)

      expect(campaign.resolve_email_connection_for_step).to eq(conn)
    end

    it "returns nil when no active connection exists for the identity" do
      campaign = Campaign.create!(base_attrs)
      expect(campaign.resolve_email_connection_for_step).to be_nil
    end
  end

  describe "#resolve_sms_sender_for_step" do
    it "returns the active company-level TwilioAccount even when campaign.channel is email" do
      twilio = TwilioAccount.create!(
        company_id: company.id, phone_number: "+15551112222",
        phone_number_sid: "PN1", status: "active"
      )
      campaign = Campaign.create!(base_attrs)  # channel defaults to 'email'
      expect(campaign.resolve_sms_sender_for_step).to eq(twilio)
    end

    it "prefers location-specific TwilioAccount when campaign has location_id" do
      location = company.locations.create!(name: "Loc A")
      TwilioAccount.create!(
        company_id: company.id, phone_number: "+15551112222",
        phone_number_sid: "PN1", status: "active"
      )
      loc_acct = TwilioAccount.create!(
        company_id: company.id, location_id: location.id,
        phone_number: "+15553334444", phone_number_sid: "PN2", status: "active"
      )

      campaign = Campaign.create!(base_attrs.merge(location_id: location.id))
      expect(campaign.resolve_sms_sender_for_step).to eq(loc_acct)
    end

    it "returns nil when no active TwilioAccount exists" do
      campaign = Campaign.create!(base_attrs)
      expect(campaign.resolve_sms_sender_for_step).to be_nil
    end
  end
end
