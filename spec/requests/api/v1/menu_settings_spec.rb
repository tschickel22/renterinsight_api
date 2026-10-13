# frozen_string_literal: true

require 'rails_helper'

# Company Settings, Customize, Menu: the side menu items a company hides.
RSpec.describe 'Api::V1 company menu settings', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  def user(role)
    User.create!(email: "u-#{SecureRandom.hex(4)}@ex.com", first_name: 'U', last_name: 'S',
                 password: 'Pass1234!', company_id: company.id, role: role)
  end

  def headers(u)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: u.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  let(:admin) { user('company_admin') }

  it 'starts with nothing hidden' do
    get '/api/v1/company/menu', headers: headers(admin)
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['hidden']).to eq([])
  end

  it 'saves hidden items, dropping junk and anything that would hide Company Settings' do
    put '/api/v1/company/menu', headers: headers(admin),
        params: { hidden: ['/contacts', 'section:Projects', '/contacts', '/settings', 'section:Administration', 'javascript:alert(1)', ''] }.to_json
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['hidden']).to eq(['/contacts', 'section:Projects'])

    get '/api/v1/company/menu', headers: headers(user('sales_rep'))
    expect(JSON.parse(response.body)['hidden']).to eq(['/contacts', 'section:Projects'])
  end

  it 'lets an empty list show everything again' do
    Setting.set('Company', company.id, 'hidden_menu_items', ['/contacts'])
    put '/api/v1/company/menu', headers: headers(admin), params: { hidden: [] }.to_json
    expect(JSON.parse(response.body)['hidden']).to eq([])
  end

  it 'refuses a change from someone who cannot edit company settings' do
    company.update!(use_rbac_system: true)
    put '/api/v1/company/menu', headers: headers(user('sales_rep')), params: { hidden: ['/contacts'] }.to_json
    expect(response).to have_http_status(:forbidden)
    expect(Setting.get('Company', company.id, 'hidden_menu_items')).to be_nil
  end
end
