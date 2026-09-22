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
