# frozen_string_literal: true

require 'rails_helper'

# Dealers arrive with contacts they already hold consent for: an old CRM, a
# signed form, a conversation on the lot. Refusing to record that protects
# nobody, it just means the consent goes unrecorded while they mail the person
# anyway. But a consent a rep ticked is weaker evidence than one a person gave,
# and that difference has to survive in the record.
RSpec.describe MarketingConsentRecorder do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:lead) do
    Lead.create!(company_id: company.id, first_name: 'Sam', last_name: 'K', email: 'sam@example.com')
  end

  def pref(channel = 'email')
    CommunicationPreference.find_by(recipient: lead, channel: channel, category: 'marketing')
  end

  it 'records consent for both channels' do
    result = described_class.call(recipient: lead, opted_in: true, user: user, basis: 'Imported from previous CRM')

    expect(result).to be_ok
    expect(CommunicationPreference.marketing_consent?(recipient: lead, channel: 'email')).to be(true)
    expect(CommunicationPreference.marketing_consent?(recipient: lead, channel: 'sms')).to be(true)
  end

  it 'stamps who entered it, when, and on what basis' do
    described_class.call(recipient: lead, opted_in: true, user: user, basis: 'Signed form on file')

    meta = pref.compliance_metadata
    expect(meta['source']).to eq('staff_entry')
    expect(meta['recorded_by_user_id']).to eq(user.id)
    expect(meta['basis']).to eq('Signed form on file')
    expect(meta['recorded_at']).to be_present
  end

  # The point of the separate source: a reviewer must be able to tell a consent
  # somebody gave from a consent somebody typed.
  it 'never passes itself off as a form capture' do
    described_class.call(recipient: lead, opted_in: true, user: user, basis: 'Old CRM')

    expect(pref.compliance_metadata['source']).not_to eq('intake_form')
    expect(pref.compliance_metadata['consent_text']).to be_nil
  end

  it 'clears the wording from an earlier form capture rather than reusing it as evidence' do
    CommunicationPreference.find_or_create_for(recipient: lead, channel: 'email', category: 'marketing')
                           .update!(compliance_metadata: { 'source' => 'intake_form',
                                                           'consent_text' => 'Yes, Acme may email me.',
                                                           'consent_version' => 'v1' })

    described_class.call(recipient: lead, opted_in: true, user: user, basis: 'Phone call')

    expect(pref.compliance_metadata['consent_text']).to be_nil
    expect(pref.compliance_metadata['consent_version']).to be_nil
    expect(pref.compliance_metadata['source']).to eq('staff_entry')
  end

  it 'refuses to record a consent without saying where it came from' do
    result = described_class.call(recipient: lead, opted_in: true, user: user, basis: '  ')

    expect(result).not_to be_ok
    expect(result.error).to match(/where this consent came from/i)
    expect(CommunicationPreference.where(recipient: lead)).to be_empty
  end

  # Honouring a "stop" must never be harder than recording a "start".
  it 'records a refusal with no basis required' do
    result = described_class.call(recipient: lead, opted_in: false, user: user)

    expect(result).to be_ok
    expect(CommunicationPreference.marketing_consent?(recipient: lead)).to be(false)
    expect(pref.opted_out_at).to be_present
  end

  it 'lets staff correct a consent they entered by mistake' do
    described_class.call(recipient: lead, opted_in: true, user: user, basis: 'Old CRM')
    described_class.call(recipient: lead, opted_in: false, user: user)

    expect(CommunicationPreference.marketing_consent?(recipient: lead)).to be(false)
  end

  it 'reports a problem rather than raising' do
    expect(described_class.call(recipient: nil, opted_in: true, user: user, basis: 'x')).not_to be_ok
  end
end
