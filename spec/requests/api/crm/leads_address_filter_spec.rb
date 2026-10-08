# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Crm::Leads address filters', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  def lead(attrs)
    Lead.create!({ company_id: company.id, first_name: 'A', last_name: 'B', status: 'new',
                   email: "l-#{SecureRandom.hex(4)}@x.com" }.merge(attrs))
  end

  before do
    lead(city: 'Denver', state: 'CO', zip: '80202')
    lead(city: 'Boulder', state: 'co', zip: '80301')
    lead(city: 'Austin', state: 'TX', zip: '73301')
  end

  def total(params)
    get '/api/crm/leads', params: params, headers: headers
    JSON.parse(response.body).dig('meta', 'total')
  end

  it('filters by state') { expect(total(state: 'CO')).to eq(2) }
  it('filters by city') { expect(total(city: 'den')).to eq(1) }
  it('filters by zip prefix') { expect(total(zip: '80')).to eq(2) }

  it 'lists the states in use, case folded, for the dropdown' do
    get '/api/crm/leads', headers: headers
    expect(JSON.parse(response.body).dig('meta', 'stats', 'by_state')).to eq('CO' => 2, 'TX' => 1)
  end
end
