# frozen_string_literal: true

require 'rails_helper'

# CommunicationPreference is polymorphic on the recipient, so a consent captured
# on a lead form belongs to the Lead row and nothing else. Converting the lead
# left the new Contact and Account holding no consent, and CampaignSender gates
# on exactly that record: converting a consenting lead made the person
# unmailable, looking for all the world like they had withdrawn.
RSpec.describe MarketingConsentTransfer do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:lead) do
    Lead.create!(company_id: company.id, first_name: 'Sam', last_name: 'K', email: 'sam@example.com')
  end
  let(:contact) do
    Contact.create!(company_id: company.id, first_name: 'Sam', last_name: 'K', email: 'sam@example.com')
  end

  def consent!(recipient, channel: 'email', opted_in: true)
    pref = CommunicationPreference.find_or_create_for(
      recipient: recipient, channel: channel, category: 'marketing'
    )
    if opted_in
      pref.opt_in!(ip_address: '203.0.113.7', user_agent: 'Mozilla/5.0')
    else
      pref.opt_out!('unsubscribed')
    end
    pref.update!(compliance_metadata: (pref.compliance_metadata || {}).merge('source' => 'intake_form'))
    pref
  end

  it 'carries both channels forward' do
    consent!(lead, channel: 'email')
    consent!(lead, channel: 'sms')

    expect(described_class.call(from: lead, to: contact)).to eq(2)
    expect(CommunicationPreference.marketing_consent?(recipient: contact, channel: 'email')).to be(true)
    expect(CommunicationPreference.marketing_consent?(recipient: contact, channel: 'sms')).to be(true)
  end

  it 'keeps the provenance so the record still proves what they were shown' do
    consent!(lead)

    described_class.call(from: lead, to: contact)

    meta = CommunicationPreference.find_by(recipient: contact, channel: 'email', category: 'marketing')
                                  .compliance_metadata
    expect(meta['source']).to eq('intake_form')
    expect(meta['carried_from']).to eq("Lead##{lead.id}")
    expect(meta['carried_at']).to be_present
  end

  it 'preserves the original opt-in timestamp rather than stamping today' do
    pref = consent!(lead)
    pref.update!(opted_in_at: 3.months.ago)

    described_class.call(from: lead, to: contact)

    carried = CommunicationPreference.find_by(recipient: contact, channel: 'email', category: 'marketing')
    expect(carried.opted_in_at).to be_within(1.second).of(pref.reload.opted_in_at)
  end

  # A conversion must never resurrect a consent the person already withdrew.
  it 'does not overwrite an opt-out the contact already made' do
    consent!(lead)
    consent!(contact, opted_in: false)

    expect(described_class.call(from: lead, to: contact)).to eq(0)
    expect(CommunicationPreference.marketing_consent?(recipient: contact)).to be(false)
  end

  it 'carries a refusal forward too, rather than leaving a blank' do
    consent!(lead, opted_in: false)

    described_class.call(from: lead, to: contact)

    carried = CommunicationPreference.find_by(recipient: contact, channel: 'email', category: 'marketing')
    expect(carried).to be_present
    expect(carried.opted_in).to be(false)
  end

  it 'does nothing when the lead never consented' do
    expect(described_class.call(from: lead, to: contact)).to eq(0)
    expect(CommunicationPreference.where(recipient: contact)).to be_empty
  end

  it 'is a no-op rather than an error when there is no target' do
    consent!(lead)
    expect(described_class.call(from: lead, to: nil)).to eq(0)
  end

  it 'never raises out into the conversion' do
    consent!(lead)
    allow(CommunicationPreference).to receive(:find_or_initialize_by).and_raise(ActiveRecord::StatementInvalid, 'boom')

    expect { described_class.call(from: lead, to: contact) }.not_to raise_error
  end
end
