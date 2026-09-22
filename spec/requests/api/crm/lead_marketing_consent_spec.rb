# frozen_string_literal: true

require 'rails_helper'

# Staff entering consent for a lead they brought in from somewhere else.
RSpec.describe 'PATCH /api/crm/leads/:id/marketing-consent', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:lead) do
    Lead.create!(company_id: company.id, first_name: 'Sam', last_name: 'K', email: 'sam@example.com')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}" }
  end

  it 'records the consent and returns it for the panel' do
    patch "/api/crm/leads/#{lead.id}/marketing-consent",
          params: { opted_in: true, basis: 'Imported from previous CRM' }, headers: headers

    expect(response).to have_http_status(:ok)
    mc = JSON.parse(response.body)['marketingConsent']
    expect(mc['optedIn']).to be(true)
    expect(mc['source']).to eq('staff_entry')
    expect(mc['basis']).to eq('Imported from previous CRM')
    expect(mc['recordedByName']).to be_present
    expect(CommunicationPreference.marketing_consent?(recipient: lead)).to be(true)
  end

  it 'refuses a consent with no stated basis' do
    patch "/api/crm/leads/#{lead.id}/marketing-consent",
          params: { opted_in: true }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(CommunicationPreference.marketing_consent?(recipient: lead)).to be(false)
  end

  it 'takes an opt-out without asking for a basis' do
    patch "/api/crm/leads/#{lead.id}/marketing-consent",
          params: { opted_in: false }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(CommunicationPreference.marketing_consent?(recipient: lead)).to be(false)
  end

  it 'will not touch a lead belonging to another company' do
    other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
    theirs = Lead.create!(company_id: other.id, first_name: 'Not', last_name: 'Ours', email: 'x@example.com')

    patch "/api/crm/leads/#{theirs.id}/marketing-consent",
          params: { opted_in: true, basis: 'nope' }, headers: headers

    expect(response).to have_http_status(:not_found).or have_http_status(:forbidden)
    expect(CommunicationPreference.marketing_consent?(recipient: theirs)).to be(false)
  end
end

# The scenario this exists to prevent: a rep types in a lead they just spoke to,
# adds them to a campaign, and the send silently skips them.
RSpec.describe 'Consent on a manually entered lead', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}" }
  end

  def create_lead(extra = {})
    post '/api/crm/leads',
         params: { lead: { first_name: 'Sam', last_name: 'K',
                           email: "s-#{SecureRandom.hex(4)}@example.com" }.merge(extra) },
         headers: headers
    Lead.find(JSON.parse(response.body)['id'])
  end

  it 'defaults to consented, so the rep is not blocked on their own lead' do
    lead = create_lead

    expect(response).to have_http_status(:created)
    expect(CommunicationPreference.marketing_consent?(recipient: lead)).to be(true)
    expect(CommunicationPreference.marketing_consent?(recipient: lead, channel: 'sms')).to be(true)
  end

  it 'records it as a staff entry, never as a form capture' do
    lead = create_lead

    meta = CommunicationPreference.find_by(recipient: lead, channel: 'email', category: 'marketing')
                                  .compliance_metadata
    expect(meta['source']).to eq('staff_entry')
    expect(meta['basis']).to match(/entered manually/i)
    expect(meta['recorded_by_user_id']).to eq(rep.id)
    expect(meta['consent_text']).to be_nil
  end

  it 'honours a rep who unticks the box' do
    lead = create_lead(marketing_consent: false)

    expect(CommunicationPreference.marketing_consent?(recipient: lead)).to be(false)
  end

  it 'still creates the lead when consent recording fails' do
    allow(MarketingConsentRecorder).to receive(:call).and_raise(StandardError, 'boom')

    post '/api/crm/leads',
         params: { lead: { first_name: 'Sam', last_name: 'K', email: 'boom@example.com' } },
         headers: headers

    expect(response).to have_http_status(:created)
    expect(Lead.find_by(email: 'boom@example.com')).to be_present
  end
end
