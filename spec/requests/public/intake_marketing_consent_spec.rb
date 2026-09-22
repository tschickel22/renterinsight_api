# frozen_string_literal: true

require 'rails_helper'

# Google asked to see "the technical implementation of the consent-gathering
# process". Before this, public lead forms captured nothing: there was no
# checkbox, no field, and nothing stored.
RSpec.describe 'Public intake form marketing consent', type: :request do
  let(:company) { Company.create!(name: 'Summit Park Homes') }
  let!(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:form) do
    IntakeForm.create!(company_id: company.id, name: 'Get a quote', is_active: true,
                       auto_create_lead: true,
                       schema: [{ 'name' => 'email', 'type' => 'email', 'label' => 'Email' }],
                       field_mappings: { 'email' => 'email', 'first_name' => 'first_name' })
  end

  def submit(payload)
    post "/f/#{form.public_id}/submit",
         params: payload.to_json,
         headers: { 'CONTENT_TYPE' => 'application/json', 'HTTP_USER_AGENT' => 'Mozilla/5.0 (Test)' }
  end

  let(:base) { { 'first_name' => 'Sam', 'email' => 'sam@example.com' } }

  it 'records consent with the provenance a reviewer asks for' do
    submit(base.merge('marketing_consent' => true))

    expect(response).to have_http_status(:ok)
    submission = IntakeSubmission.last
    expect(submission.marketing_consent).to be(true)
    expect(submission.marketing_consent_at).to be_present
    expect(submission.marketing_consent_text).to include('Summit Park Homes')

    lead = Lead.find(submission.lead_id)
    pref = CommunicationPreference.find_by(recipient: lead, channel: 'email', category: 'marketing')
    expect(pref.opted_in).to be(true)
    expect(pref.ip_address).to be_present
    expect(pref.user_agent).to include('Mozilla/5.0')

    meta = pref.compliance_metadata
    expect(meta['source']).to eq('intake_form')
    expect(meta['intake_form_id']).to eq(form.id)
    expect(meta['consent_text']).to include('Summit Park Homes')
    expect(meta['consent_version']).to eq('v1')
  end

  it 'still captures the lead when the box is left unchecked, without consent' do
    submit(base)

    expect(response).to have_http_status(:ok)
    submission = IntakeSubmission.last
    expect(submission.marketing_consent).to be(false)
    expect(submission.marketing_consent_text).to be_nil

    lead = Lead.find(submission.lead_id)
    expect(CommunicationPreference.marketing_consent?(recipient: lead)).to be(false)
  end

  it 'treats an explicit false as refusal' do
    submit(base.merge('marketing_consent' => false))

    expect(IntakeSubmission.last.marketing_consent).to be(false)
  end

  it 'does not store the consent flag as if it were a form answer' do
    submit(base.merge('marketing_consent' => true))

    expect(IntakeSubmission.last.data).not_to have_key('marketing_consent')
  end

  it 'ignores a claimed consent on a form that does not ask for it' do
    form.update!(marketing_consent_enabled: false)

    submit(base.merge('marketing_consent' => true))

    expect(IntakeSubmission.last.marketing_consent).to be(false)
  end

  # Editing the form later must not rewrite what somebody already agreed to.
  it 'copies the wording rather than referencing it' do
    form.update!(marketing_consent_text: 'Original wording from {{company}}.')
    submit(base.merge('marketing_consent' => true))
    stored = IntakeSubmission.last.marketing_consent_text

    form.update!(marketing_consent_text: 'Completely different wording.')

    expect(stored).to eq('Original wording from Summit Park Homes.')
    expect(IntakeSubmission.last.reload.marketing_consent_text).to eq(stored)
  end
end
