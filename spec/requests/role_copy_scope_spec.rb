# frozen_string_literal: true

require 'rails_helper'

# Duplicating a shared role is the only way a dealer changes one. Copies used to
# come out company-tier whatever the original was, and a company-tier role gives
# its people every location, so copying Sales Rep quietly widened access. The
# Roles screen also showed "0 users" on every role.
RSpec.describe 'Role copies and user counts', type: :request do
  let(:company) { create(:company, use_rbac_system: true) }
  let(:other_company) { create(:company, use_rbac_system: true) }
  let!(:admin) { make_user('company_admin', company) }

  let!(:location_role) do
    Role.create!(key: "loc_#{SecureRandom.hex(3)}", name: 'Rep', tier: 'location', is_system_role: true, company_id: nil, active: true)
  end
  let!(:company_role) do
    Role.create!(key: "co_#{SecureRandom.hex(3)}", name: 'Manager', tier: 'company', is_system_role: true, company_id: nil, active: true)
  end

  def make_user(role, co)
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U', last_name: 'Ser', password: 'Pass1234!',
                 company_id: co.id, role: role, status: 'active')
  end

  def auth(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }

  def assign(user, role, co)
    UserRoleAssignment.create!(user: user, role: role, tier: 'company', company_id: co.id)
  end

  it 'a copy of a location role stays a location role, even when the browser asks for company' do
    post "/api/v1/roles/#{location_role.id}/clone", params: { display_name: 'Our rep', tier: 'company' }, headers: auth(admin), as: :json

    expect(response).to have_http_status(:created)
    expect(Role.find_by(name: 'Our rep').tier).to eq('location')
  end

  it 'a copy of a company role stays a company role' do
    post "/api/v1/roles/#{company_role.id}/clone", params: { display_name: 'Our manager' }, headers: auth(admin), as: :json

    expect(Role.find_by(name: 'Our manager').tier).to eq('company')
  end

  it 'counts people holding a shared role in this company only' do
    2.times { assign(make_user('user', company), location_role, company) }
    assign(make_user('user', other_company), location_role, other_company)
    expired = make_user('user', company)
    UserRoleAssignment.create!(user: expired, role: location_role, tier: 'company', company_id: company.id, expires_at: 1.day.ago)

    get '/api/v1/roles', headers: auth(admin)

    counts = JSON.parse(response.body)['roles'].to_h { |r| [r['id'], r['users_count']] }
    expect(counts[location_role.id]).to eq(2)
    expect(counts[company_role.id]).to eq(0)
  end
end
