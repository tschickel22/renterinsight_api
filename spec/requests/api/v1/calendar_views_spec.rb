# frozen_string_literal: true

require 'rails_helper'

# The calendar opens on 'my'. Roles granted only a wider read scope were refused
# it, so the page failed with a 403 for them.
RSpec.describe 'Calendar views by read scope', type: :request do
  let(:company) { create(:company, name: 'Scope Homes') }
  let(:resource) { Resource.find_or_create_by!(key: 'calendar') { |r| r.name = 'Calendar' } }
  let(:read) { Action.find_or_create_by!(key: 'read') { |a| a.name = 'Read' } }

  def user_with_scopes(*scope_keys)
    role = Role.create!(company_id: company.id, tier: 'company', key: "r_#{SecureRandom.hex(3)}", name: "Role #{SecureRandom.hex(3)}")
    scope_keys.each do |key|
      scope = Scope.find_or_create_by!(key: key) { |s| s.name = key }
      RolePermission.create!(role: role, resource: resource, action: read, scope: scope, granted: true)
    end
    user = User.create!(email: "u#{SecureRandom.hex(3)}@scope.example", first_name: 'U', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: role.name, status: 'active')
    UserRoleAssignment.create!(user: user, role: role, company_id: company.id, tier: 'company', assigned_at: Time.current)
    user
  end

  def headers_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }
  end

  def status_for(user, view)
    get '/api/v1/calendar/events', params: { view: view }, headers: headers_for(user)
    response.status
  end

  def offered_views(user)
    get '/api/v1/calendar/views', headers: headers_for(user)
    JSON.parse(response.body)['views'].map { |v| v['id'] }
  end

  it 'lets a role with read all open my and team' do
    user = user_with_scopes('all')
    expect(status_for(user, 'my')).to eq(200)
    expect(status_for(user, 'team')).to eq(200)
    expect(status_for(user, 'all')).to eq(200)
    expect(offered_views(user)).to include('my', 'team', 'all')
  end

  it 'lets a role with read assigned_locations open my and team, not all' do
    user = user_with_scopes('assigned_locations')
    expect(status_for(user, 'my')).to eq(200)
    expect(status_for(user, 'team')).to eq(200)
    expect(status_for(user, 'all')).to eq(403)
    expect(offered_views(user)).to include('my', 'team')
    expect(offered_views(user)).not_to include('all')
  end

  it 'keeps a role with read own to my' do
    user = user_with_scopes('own')
    expect(status_for(user, 'my')).to eq(200)
    expect(status_for(user, 'team')).to eq(403)
    expect(offered_views(user)).to eq(['my'])
  end

  it 'still refuses a role with no calendar read' do
    user = user_with_scopes
    expect(status_for(user, 'my')).to eq(403)
    expect(offered_views(user)).to eq([])
  end
end
