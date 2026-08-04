require 'rails_helper'

RSpec.describe Vendor, 'SMS consent' do
  let(:company) { create(:company) }
  let(:user) { User.create!(company: company, email: "u#{SecureRandom.hex(4)}@example.com", first_name: 'Dana', last_name: 'Reyes', password: 'password123', status: 'active') }

  let(:contractor) do
    Contractor.create!(
      company: company, name: 'Anchor Set Crew', vendor_type: 'contractor',
      status: 'active', phone: '337-555-0100', email: 'crew@example.com'
    )
  end

  it 'defaults to no consent' do
    expect(contractor.sms_opt_in).to be_falsey
    expect(contractor.can_receive_sms?).to be false
  end

  it 'records provenance when a dealer grants consent' do
    contractor.record_sms_consent!(
      opted_in: true, source: 'dealer_recorded', user: user,
      note: 'Verbal consent on signed subcontractor agreement'
    )
    contractor.reload

    expect(contractor.sms_opt_in).to be true
    expect(contractor.sms_consent_source).to eq('dealer_recorded')
    expect(contractor.sms_consent_recorded_by_id).to eq(user.id)
    expect(contractor.sms_consent_note).to match(/signed subcontractor/i)
    expect(contractor.sms_consent_recorded_at).to be_present
  end

  it 'refuses to grant consent without a source' do
    expect {
      contractor.record_sms_consent!(opted_in: true, source: nil, user: user)
    }.to raise_error(ArgumentError, /source is required/)

    expect(contractor.reload.sms_opt_in).to be_falsey
  end

  it 'allows revoking without a source' do
    contractor.record_sms_consent!(opted_in: true, source: 'contractor_portal')
    expect {
      contractor.record_sms_consent!(opted_in: false)
    }.not_to raise_error

    expect(contractor.reload.sms_opt_in).to be false
  end

  it 'keeps the prior source after revocation as the historical record' do
    contractor.record_sms_consent!(opted_in: true, source: 'contractor_portal')
    contractor.record_sms_consent!(opted_in: false, user: user)
    contractor.reload

    expect(contractor.sms_opt_in).to be false
    expect(contractor.sms_consent_source).to eq('contractor_portal')
  end

  it 'rejects an unrecognized consent source' do
    contractor.sms_consent_source = 'overheard_at_a_bar'
    expect(contractor).not_to be_valid
    expect(contractor.errors[:sms_consent_source]).to be_present
  end

  it 'does not consider a contractor textable without a phone number' do
    contractor.record_sms_consent!(opted_in: true, source: 'dealer_recorded', note: 'x')
    contractor.update!(phone: nil)

    expect(contractor.sms_opt_in).to be true
    expect(contractor.can_receive_sms?).to be false
  end

  it 'exposes consent state for the API' do
    contractor.record_sms_consent!(
      opted_in: true, source: 'dealer_recorded', user: user, note: 'Signed agreement'
    )

    json = contractor.reload.sms_consent_json
    expect(json[:smsOptIn]).to be true
    expect(json[:canReceiveSms]).to be true
    expect(json[:consentSource]).to eq('dealer_recorded')
    expect(json[:consentRecordedBy]).to eq('Dana Reyes')
    expect(json[:consentNote]).to eq('Signed agreement')
  end
end
