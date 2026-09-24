# frozen_string_literal: true

require 'rails_helper'

# The consent block was added to the show action alone at first. The form
# builder loads its list from #index, so its preview drew no consent question:
# an admin checking their own form saw something their visitors would not.
# Resolving it in as_json is what stops the next endpoint missing it too.
RSpec.describe 'IntakeForm consent serialization' do
  let(:company) { Company.create!(name: 'Summit Park Homes') }
  let(:form) do
    IntakeForm.create!(company_id: company.id, name: 'Contact Us', is_active: true,
                       schema: [{ 'name' => 'email', 'type' => 'email', 'label' => 'Email' }])
  end

  it 'carries the consent block on every serialization, not just one endpoint' do
    json = form.as_json

    expect(json['marketing_consent']['enabled']).to be(true)
    expect(json['marketing_consent']['text']).to include('Summit Park Homes')
    expect(json['marketing_consent']['version']).to eq('v1')
  end

  it 'reports it as off when the dealer turned the question off' do
    form.update!(marketing_consent_enabled: false)

    expect(form.as_json['marketing_consent']['enabled']).to be(false)
  end

  it 'uses the dealer wording when they wrote their own' do
    form.update!(marketing_consent_text: 'Text me deals from {{company}}.')

    expect(form.as_json['marketing_consent']['text']).to eq('Text me deals from Summit Park Homes.')
  end

  describe 'the endpoints the builder and the visitor actually use', type: :request do
    let(:admin) do
      User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D',
                   password: 'Pass1234!', company_id: company.id, role: 'company_admin')
    end
    let(:headers) do
      { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" }
    end

    it 'includes it in the builder list, which is where the preview reads it' do
      form
      get '/api/crm/intake/forms', headers: headers

      expect(response).to have_http_status(:ok)
      listed = JSON.parse(response.body).find { |f| f['id'] == form.id }
      expect(listed['marketing_consent']['enabled']).to be(true)
      expect(listed['marketing_consent']['text']).to be_present
    end

    it 'includes it on the public form a visitor loads' do
      get "/f/#{form.public_id}"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['marketing_consent']['enabled']).to be(true)
    end
  end
end
