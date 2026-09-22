# frozen_string_literal: true

require 'rails_helper'

# CampaignSender skips a recipient with no consent record. On its own that is
# silent: a dealer who imported a book of contacts watches a send of 800 quietly
# become a send of 40 with nothing saying why. This is the number that has to be
# on screen before they press start.
RSpec.describe Campaigns::ConsentCoverage do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'R', last_name: 'P',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: rep.id, name: 'Weekly',
                         campaign_type: 'blast', channel: 'email', from_identity_type: 'User',
                         from_identity_id: rep.id, throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                             body_blocks: [{ 'type' => 'text', 'html' => 'Hi' }])
    c
  end

  def enrolled_lead(consent: nil)
    lead = Lead.create!(company_id: company.id, first_name: 'S', last_name: 'K',
                        email: "l-#{SecureRandom.hex(4)}@example.com")
    unless consent.nil?
      pref = CommunicationPreference.find_or_create_for(recipient: lead, channel: 'email', category: 'marketing')
      consent ? pref.opt_in! : pref.opt_out!('no thanks')
    end
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                               recipient_id: lead.id, email_address_snapshot: lead.email, status: 'pending')
    lead
  end

  it 'separates consented, opted out, and never asked' do
    enrolled_lead(consent: true)
    enrolled_lead(consent: true)
    enrolled_lead(consent: false)
    enrolled_lead

    result = described_class.for_campaign(campaign)

    expect(result.total).to eq(4)
    expect(result.consented).to eq(2)
    expect(result.opted_out).to eq(1)
    expect(result.missing).to eq(1)
    expect(result.blocked).to eq(2)
    expect(result).not_to be_all_covered
  end

  it 'reports a fully consented audience as clear' do
    2.times { enrolled_lead(consent: true) }

    result = described_class.for_campaign(campaign)

    expect(result.blocked).to eq(0)
    expect(result).to be_all_covered
  end

  it 'reports the gate as on when the tenant has no setting' do
    enrolled_lead(consent: true)
    expect(described_class.for_campaign(campaign).gate_enabled).to be(true)
  end

  # Telling a grandfathered tenant that recipients will be skipped would be a lie.
  it 'reports the gate as off for a tenant that opted out of it' do
    Setting.set('Company', company.id, 'require_marketing_consent', false)
    enrolled_lead

    result = described_class.for_campaign(campaign)

    expect(result.gate_enabled).to be(false)
    expect(result.missing).to eq(1)
  end

  it 'returns zeroes rather than raising when the audience cannot be resolved' do
    expect(described_class.for_campaign(campaign).total).to eq(0)
  end
end
