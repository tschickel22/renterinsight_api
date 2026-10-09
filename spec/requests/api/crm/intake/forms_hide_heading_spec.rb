# frozen_string_literal: true

require 'rails_helper'

# A form on a website usually sits under the page's own heading, so its name
# and description can be left off where visitors see it.
RSpec.describe 'Intake form hide name and description', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@x.com", first_name: 'A', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end
  let!(:form) do
    IntakeForm.create!(company_id: company.id, name: 'Website Contact', description: 'Say hello',
                       schema: [], is_active: true, auto_create_lead: true, auto_create_activity: false)
  end

  it 'saves both switches from the builder, in either key style' do
    patch "/api/crm/intake/forms/#{form.id}",
          params: { intake_form: { hideName: true, hide_description: 'true', fields: [] } }.to_json,
          headers: headers

    expect(response).to have_http_status(:ok)
    expect(form.reload.hide_name).to be true
    expect(form.hide_description).to be true
    expect(JSON.parse(response.body)).to include('hideName' => true, 'hideDescription' => true)
  end

  it 'tells the public page what to hide' do
    form.update!(hide_name: true)

    json = form.public_as_json

    expect(json).to include('hide_name' => true, 'hideName' => true, 'hide_description' => false)
  end
end
