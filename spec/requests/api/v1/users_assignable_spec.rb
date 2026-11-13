# frozen_string_literal: true

require 'rails_helper'

# New Deal's "Assign To" loaded GET /api/v1/users, which needs users:read, so a
# sales rep saw an empty box. The picker now uses /users/assignable, which any
# signed-in user of the company may call and which returns only what a picker
# shows.
RSpec.describe 'GET /api/v1/users/assignable', type: :request do
  let(:company) do
    Company.create!(name: "Assign Co #{SecureRandom.hex(4)}", industry: 'manufactured_housing', use_rbac_system: true)
  end
  let(:other_company) { Company.create!(name: "Other Co #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:other_location) { company.locations.create!(name: 'Lot Two', timezone: 'America/Denver') }

  before do
    Resource.seed_defaults
    Action.seed_defaults
    Scope.seed_defaults
  end

  def make_user(co, first, status: 'active', role: 'user', phone: nil)
    co.users.create!(email: "#{first.downcase}-#{SecureRandom.hex(3)}@example.com", first_name: first,
                     last_name: 'Tester', password: 'Pass1234!', role: role, status: status, phone: phone)
  end

  let(:rep) do
    role = Role.create!(company_id: company.id, key: "rep-#{SecureRandom.hex(3)}", name: 'Sales Representative',
                        tier: 'location', active: true)
    role.grant_permission!('deals', 'create')
    user = make_user(company, 'Rita', phone: '7205550100')
    user.user_role_assignments.create!(role: role, company_id: company.id, tier: 'location', location: location)
    user
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}" } }

  it 'lists every active user of the company to a rep without users:read' do
    expect(rep.has_permission?('users', 'read', 'all', company.id)).to be false
    elsewhere = make_user(company, 'Elsa')
    elsewhere.user_locations.create!(location: other_location, active: true) if elsewhere.respond_to?(:user_locations)
    make_user(company, 'Gone', status: 'inactive')
    make_user(company, 'Buyer', role: 'client')
    make_user(other_company, 'Outsider')

    get '/api/v1/users/assignable', headers: headers

    expect(response).to have_http_status(:ok)
    names = JSON.parse(response.body)['users'].map { |u| u['firstName'] }
    expect(names).to contain_exactly('Rita', 'Elsa')
  end

  it 'returns only what a picker shows, never email or phone' do
    rep

    get '/api/v1/users/assignable', headers: headers

    row = JSON.parse(response.body)['users'].first
    expect(row.keys).to contain_exactly('id', 'firstName', 'lastName', 'fullName', 'displayRole', 'avatarUrl')
    expect(response.body).not_to include('@example.com')
    expect(response.body).not_to include('7205550100')
    expect(row['displayRole']).to eq('Sales Representative')
  end
end
