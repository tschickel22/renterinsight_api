# frozen_string_literal: true

require 'rails_helper'

# Regression spec for the "edited location doesn't persist" bug.
# The FE spreads ...formData (which carries a camelCase locationId echo from
# as_json) AND emits the fresh snake_case location_id. Both keys arrive here.
# The strong-params tap must prefer the snake_case value; the old code did
# `p[:location_id] = p.delete(:locationId)` unconditionally, silently
# reverting every edit.
RSpec.describe 'Api::Crm::Intake::Forms location_id persistence', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:loc_a)   { Location.create!(company_id: company.id, name: 'A', code: 'A', active: true) }
  let(:loc_b)   { Location.create!(company_id: company.id, name: 'B', code: 'B', active: true) }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@x.com", first_name: 'A', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: admin.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let!(:form) do
    IntakeForm.create!(company_id: company.id, name: 'F', schema: [], is_active: true,
                       location_id: loc_a.id, auto_create_lead: true, auto_create_activity: false)
  end

  it 'honors the new snake_case location_id even when a stale camelCase locationId is also sent' do
    patch "/api/crm/intake/forms/#{form.id}",
          params: { intake_form: { locationId: loc_a.id, location_id: loc_b.id, fields: [] } }.to_json,
          headers: headers
    expect(response).to have_http_status(:ok)
    expect(form.reload.location_id).to eq(loc_b.id)
  end

  it 'still accepts a camelCase-only payload from older clients' do
    patch "/api/crm/intake/forms/#{form.id}",
          params: { intake_form: { locationId: loc_b.id, fields: [] } }.to_json,
          headers: headers
    expect(response).to have_http_status(:ok)
    expect(form.reload.location_id).to eq(loc_b.id)
  end

  it 'clears location_id when payload sends null (any-location fallback)' do
    patch "/api/crm/intake/forms/#{form.id}",
          params: { intake_form: { location_id: nil, fields: [] } }.to_json,
          headers: headers
    expect(response).to have_http_status(:ok)
    expect(form.reload.location_id).to be_nil
  end
end
