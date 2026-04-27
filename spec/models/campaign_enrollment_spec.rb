# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CampaignEnrollment, type: :model do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:user) { User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "T", last_name: "U", password: "Pass1234!", company_id: company.id) }
  let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id,
                     name: "C", campaign_type: "drip", from_identity_type: "User",
                     from_identity_id: user.id, throttle_per_day: 100)
  end
  let(:lead) do
    Lead.create!(company: company, source: source,
                 first_name: "Buyer", last_name: "One",
                 email: "buyer-#{SecureRandom.hex(4)}@example.com")
  end

  it "enforces uniqueness on (campaign_id, recipient_type, recipient_id)" do
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
      recipient_type: "Lead", recipient_id: lead.id, email_address_snapshot: lead.email)
    dup = CampaignEnrollment.new(company_id: company.id, campaign_id: campaign.id,
      recipient_type: "Lead", recipient_id: lead.id, email_address_snapshot: lead.email)
    expect(dup).not_to be_valid
    expect(dup.errors[:recipient_id]).to include(a_string_matching(/taken/i))
  end

  describe "#advance_to_next_step" do
    let!(:step0) { campaign.campaign_steps.create!(position: 0, is_active: true, wait_days: 0, wait_hours: 0, body_blocks: [{ "type" => "text", "html" => "0" }]) }
    let!(:step1) { campaign.campaign_steps.create!(position: 1, is_active: true, wait_days: 2, wait_hours: 3, body_blocks: [{ "type" => "text", "html" => "1" }]) }

    let(:enr) do
      CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
        recipient_type: "Lead", recipient_id: lead.id,
        email_address_snapshot: lead.email, current_step_index: 0,
        status: "active")
    end

    it "advances to next step and sets next_send_at" do
      freeze_time do
        enr.advance_to_next_step
        expect(enr.current_step_index).to eq(1)
        expected = Time.current + (2 * 86400 + 3 * 3600).seconds
        expect(enr.next_send_at).to be_within(1.second).of(expected)
      end
    end

    it "completes when no more steps remain" do
      enr.update!(current_step_index: 1)
      enr.advance_to_next_step
      expect(enr.status).to eq("completed")
    end
  end
end
