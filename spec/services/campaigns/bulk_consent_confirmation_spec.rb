# frozen_string_literal: true

require 'rails_helper'

# The step that turns the consent gate from a wall into a question. Without it a
# dealer who imported a book of contacts has no route forward except ticking
# hundreds of leads by hand, which nobody does: they turn the gate off instead,
# and then it protects no one.
RSpec.describe Campaigns::BulkConsentConfirmation do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'Rita', last_name: 'Rep',
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

  it 'confirms the recipients nobody ever asked' do
    a = enrolled_lead
    b = enrolled_lead

    result = described_class.call(campaign: campaign, user: rep, basis: 'Imported from previous CRM')

    expect(result).to be_ok
    expect(result.confirmed).to eq(2)
    expect(CommunicationPreference.marketing_consent?(recipient: a)).to be(true)
    expect(CommunicationPreference.marketing_consent?(recipient: b)).to be(true)
  end

  # The rule that stops this being a "make everything mailable" button.
  it 'never overturns somebody who opted out' do
    refuser = enrolled_lead(consent: false)
    enrolled_lead

    result = described_class.call(campaign: campaign, user: rep, basis: 'Imported')

    expect(result.confirmed).to eq(1)
    expect(CommunicationPreference.marketing_consent?(recipient: refuser)).to be(false)
  end

  it 'leaves an existing consent alone rather than restamping it' do
    already = enrolled_lead(consent: true)
    original = CommunicationPreference.find_by(recipient: already, channel: 'email', category: 'marketing')
                                      .opted_in_at

    described_class.call(campaign: campaign, user: rep, basis: 'Imported')

    expect(CommunicationPreference.find_by(recipient: already, channel: 'email', category: 'marketing').opted_in_at)
      .to be_within(1.second).of(original)
  end

  it 'records every row as a staff entry naming who confirmed it' do
    lead = enrolled_lead

    described_class.call(campaign: campaign, user: rep, basis: 'Signed forms on file')

    meta = CommunicationPreference.find_by(recipient: lead, channel: 'email', category: 'marketing')
                                  .compliance_metadata
    expect(meta['source']).to eq('staff_entry')
    expect(meta['basis']).to eq('Signed forms on file')
    expect(meta['recorded_by_user_id']).to eq(rep.id)
    expect(meta['consent_text']).to be_nil
  end

  it 'refuses to assert consent for hundreds of people with no reason given' do
    enrolled_lead

    result = described_class.call(campaign: campaign, user: rep, basis: '   ')

    expect(result).not_to be_ok
    expect(result.error).to match(/where this consent came from/i)
    expect(CommunicationPreference.count).to eq(0)
  end

  it 'refuses an audience larger than the cap rather than asserting consent for a database' do
    enrolled_lead
    stub_const('Campaigns::BulkConsentConfirmation::MAX_RECIPIENTS', 0)

    result = described_class.call(campaign: campaign, user: rep, basis: 'Imported')

    expect(result).not_to be_ok
    expect(result.error).to match(/more than the 0/i)
  end

  it 'is a no-op on an audience that already has full consent' do
    enrolled_lead(consent: true)

    result = described_class.call(campaign: campaign, user: rep, basis: 'Imported')

    expect(result).to be_ok
    expect(result.confirmed).to eq(0)
  end
end
