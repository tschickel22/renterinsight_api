# frozen_string_literal: true

require 'rails_helper'

# The users list labelled everyone by the legacy `role` string column, which is
# 'user' for anyone created since RBAC arrived. A persona picker built on that
# would read "Tom Schickel - user" rather than "Sales Representative".
RSpec.describe 'Api::V1 users RBAC labels', type: :request do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing',
                    use_rbac_system: true)
  end
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:admin) do
    company.users.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A',
                          last_name: 'Admin', password: 'Pass1234!', role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }

  before do
    Resource.seed_defaults
    Action.seed_defaults
    Scope.seed_defaults
  end

  def rep_with_role(role_name)
    role = Role.create!(company_id: company.id, key: "r-#{SecureRandom.hex(3)}", name: role_name,
                        tier: 'location', active: true)
    user = company.users.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Rep',
                                 last_name: 'One', password: 'Pass1234!', role: 'user')
    user.user_role_assignments.create!(role: role, company_id: company.id, tier: 'location',
                                       location: location)
    user
  end

  it 'labels a user by the role they actually hold, not the legacy column' do
    rep = rep_with_role('Sales Representative')

    get '/api/v1/users', headers: headers

    expect(response).to have_http_status(:ok)
    row = JSON.parse(response.body)['users'].find { |u| u['id'] == rep.id }
    expect(row['role']).to eq('user')                        # legacy column, unchanged
    expect(row['role_label']).to eq('Sales Representative')  # what a picker should show
    expect(row['rbac_roles'].map { |r| r['name'] }).to eq(['Sales Representative'])
  end

  it 'falls back to the legacy column when no role is assigned' do
    orphan = company.users.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'No',
                                   last_name: 'Role', password: 'Pass1234!', role: 'staff')

    get '/api/v1/users', headers: headers

    row = JSON.parse(response.body)['users'].find { |u| u['id'] == orphan.id }
    expect(row['rbac_roles']).to eq([])
    expect(row['role_label']).to eq('staff')
  end

  it 'lists every role when a user holds more than one' do
    rep = rep_with_role('Sales Representative')
    second = Role.create!(company_id: company.id, key: "r2-#{SecureRandom.hex(3)}",
                          name: 'Service Technician', tier: 'location', active: true)
    rep.user_role_assignments.create!(role: second, company_id: company.id, tier: 'location',
                                      location: location)

    get '/api/v1/users', headers: headers

    row = JSON.parse(response.body)['users'].find { |u| u['id'] == rep.id }
    expect(row['rbac_roles'].map { |r| r['name'] })
      .to contain_exactly('Sales Representative', 'Service Technician')
  end
end
