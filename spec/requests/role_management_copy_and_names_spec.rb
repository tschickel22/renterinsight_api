# frozen_string_literal: true

require 'rails_helper'

# Role Management: a company copies its own custom roles (the copy button used to
# show on them and then fail), two roles in one company may not share a name (the
# user pickers list roles by name, so From Template made a second "Sales
# Representative" nobody could tell apart), and only administrators hide roles.
RSpec.describe 'Role copies, names and hiding', type: :request do
  let(:company) { create(:company, use_rbac_system: true) }
  let(:other_company) { create(:company, use_rbac_system: true) }
  let!(:admin) { make_user('company_admin', company) }

  let!(:shared_role) do
    Role.create!(key: "rep_#{SecureRandom.hex(3)}", name: 'Shared Rep', tier: 'location', is_system_role: true, company_id: nil, active: true)
  end

  def make_user(role, co)
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U', last_name: 'Ser', password: 'Pass1234!',
                 company_id: co.id, role: role, status: 'active')
  end

  def auth(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }

  def custom_role(co, name, tier: 'location')
    Role.create!(key: "c_#{SecureRandom.hex(3)}", name: name, tier: tier, is_system_role: false, company_id: co.id, active: true)
  end

  describe 'copying a custom role' do
    it 'copies the company\'s own custom role, keeping its tier and permissions' do
      source = custom_role(company, 'Our Closer', tier: 'company')
      resource = Resource.first || Resource.create!(key: "res_#{SecureRandom.hex(3)}", name: 'Thing', category: 'operations')
      action = Action.first || Action.create!(key: "act_#{SecureRandom.hex(3)}", name: 'Read')
      scope = Scope.first || Scope.create!(key: "all_#{SecureRandom.hex(3)}", name: 'All')
      RolePermission.create!(role: source, resource: resource, action: action, scope: scope, granted: true)

      post "/api/v1/roles/#{source.id}/clone", params: { display_name: 'Our Closer (Copy)', tier: 'location' }, headers: auth(admin), as: :json

      expect(response).to have_http_status(:created)
      copy = Role.find_by(name: 'Our Closer (Copy)')
      expect(copy.company_id).to eq(company.id)
      expect(copy.is_system_role).to be(false)
      expect(copy.tier).to eq('company')
      expect(copy.role_permissions.pluck(:resource_id, :action_id)).to eq([[resource.id, action.id]])
    end

    it 'will not copy another company\'s custom role' do
      theirs = custom_role(other_company, 'Their Role')

      post "/api/v1/roles/#{theirs.id}/clone", params: { display_name: 'Stolen' }, headers: auth(admin), as: :json

      expect(response).to have_http_status(:not_found)
      expect(Role.find_by(name: 'Stolen')).to be_nil
    end
  end

  describe 'names are unique within a company' do
    it 'refuses a copy named like a shared role' do
      post "/api/v1/roles/#{shared_role.id}/clone", params: { display_name: 'shared rep' }, headers: auth(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('already used')
    end

    it 'refuses a new role named like one of the company\'s own' do
      custom_role(company, 'Closer')

      post '/api/v1/roles', params: { role: { key: "k_#{SecureRandom.hex(3)}", name: 'Closer', tier: 'location' } }, headers: auth(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'refuses renaming a role to a name already taken' do
      custom_role(company, 'Closer')
      other = custom_role(company, 'Opener')

      patch "/api/v1/roles/#{other.id}", params: { role: { name: 'Closer' } }, headers: auth(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(other.reload.name).to eq('Opener')
    end

    it 'lets another company use the same name' do
      custom_role(other_company, 'Closer')

      post '/api/v1/roles', params: { role: { key: "k_#{SecureRandom.hex(3)}", name: 'Closer', tier: 'location' } }, headers: auth(admin), as: :json

      expect(response).to have_http_status(:created)
    end

    it 'still saves other changes to a role whose name already clashed before the rule' do
      clash = custom_role(company, 'Twin')
      clash.update_column(:name, 'Shared Rep')

      patch "/api/v1/roles/#{clash.id}", params: { role: { description: 'Updated' } }, headers: auth(admin), as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'hiding a shared role' do
    it 'is refused for someone who is not an administrator' do
      staff = make_user('user', company)

      post "/api/v1/roles/#{shared_role.id}/toggle_visibility", headers: auth(staff), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(CompanyHiddenRole.role_hidden_for_company?(company.id, shared_role.id)).to be(false)
    end

    it 'works for an administrator and shows in the role list' do
      post "/api/v1/roles/#{shared_role.id}/toggle_visibility", headers: auth(admin), as: :json
      expect(response).to have_http_status(:ok)

      get '/api/v1/roles', headers: auth(admin)
      row = JSON.parse(response.body)['roles'].find { |r| r['id'] == shared_role.id }
      expect(row['is_hidden_for_company']).to be(true)
    end
  end
end
