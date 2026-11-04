# frozen_string_literal: true

require 'rails_helper'

# System roles and standard templates are single rows every company shares. A
# company admin could change or delete them for all dealers, and the template
# screen trusted a company id from the browser. Companies now copy instead.
RSpec.describe 'Shared roles and templates', type: :request do
  let(:company) { create(:company, use_rbac_system: true) }
  let(:other_company) { create(:company, use_rbac_system: true) }
  let!(:admin) { make_user('company_admin', company) }
  let!(:platform) { make_user('platform_admin', company) }

  let!(:resource) { Resource.create!(key: "res_#{SecureRandom.hex(3)}", name: 'Thing', category: 'core') }
  let!(:action) { Action.create!(key: "act_#{SecureRandom.hex(3)}", name: 'Do') }
  let!(:scope) { Scope.create!(key: "sco_#{SecureRandom.hex(3)}", name: 'Some') }
  let!(:system_role) do
    Role.create!(key: "sys_#{SecureRandom.hex(3)}", name: 'Standard', tier: 'company', is_system_role: true, company_id: nil, active: true)
  end
  let!(:grant) { RolePermission.create!(role: system_role, resource: resource, action: action, scope: scope, granted: true) }
  let(:own_role) { Role.create!(key: "own_#{SecureRandom.hex(3)}", name: 'Ours', tier: 'company', is_system_role: false, company_id: company.id, active: true) }

  def make_user(role, co)
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U', last_name: 'Ser', password: 'Pass1234!',
                 company_id: co.id, role: role, status: 'active')
  end

  def auth(user, extra = {}) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }.merge(extra)

  def template(company_id: nil, name: 'Standard invite')
    CommunicationTemplate.create!(name: name, template_type: 'company_user_invitation', channel: 'email',
                                  subject: 'Hello', body: 'Join us', is_active: true, company_id: company_id)
  end

  describe 'system roles' do
    it 'a company admin cannot wipe a system role' do
      put "/api/v1/roles/#{system_role.id}/permissions", params: { permissions: [] }, headers: auth(admin), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)['error']).to include('Duplicate it')
      expect(system_role.role_permissions.count).to eq(1)
    end

    it 'a company admin cannot rename a system role' do
      patch "/api/v1/roles/#{system_role.id}", params: { role: { name: 'Hacked' } }, headers: auth(admin), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(system_role.reload.name).to eq('Standard')
    end

    it 'a company admin still changes its own role and can duplicate a system one' do
      put "/api/v1/roles/#{own_role.id}/permissions",
          params: { permissions: [{ resource_id: resource.id, action_id: action.id, scope_id: scope.id, granted: true }] },
          headers: auth(admin), as: :json
      expect(response).to have_http_status(:ok)
      expect(own_role.role_permissions.count).to eq(1)

      post "/api/v1/roles/#{system_role.id}/clone", params: { display_name: 'Our standard' }, headers: auth(admin), as: :json
      expect(response).to have_http_status(:created)
      copy = Role.find_by(name: 'Our standard')
      expect(copy.company_id).to eq(company.id)
      expect(copy.role_permissions.count).to eq(1)
    end

    it 'the platform team can still change a system role' do
      put "/api/v1/roles/#{system_role.id}/permissions", params: { permissions: [] }, headers: auth(platform), as: :json
      expect(response).to have_http_status(:ok)
      expect(system_role.role_permissions.count).to eq(0)

      patch "/api/v1/roles/#{system_role.id}", params: { role: { name: 'Renamed' } }, headers: auth(platform), as: :json
      expect(response).to have_http_status(:ok)
      expect(system_role.reload.name).to eq('Renamed')
    end
  end

  describe 'standard templates' do
    let!(:standard) { template }
    let(:base) { '/api/platform/communications/templates' }

    it 'a company admin can read it but not change or delete it' do
      get "#{base}/#{standard.id}", headers: auth(admin)
      expect(response).to have_http_status(:ok)

      patch "#{base}/#{standard.id}", params: { template: { is_active: false, body: 'Changed' } }, headers: auth(admin), as: :json
      expect(response).to have_http_status(:forbidden)
      expect(standard.reload).to have_attributes(is_active: true, body: 'Join us')

      delete "#{base}/#{standard.id}", headers: auth(admin)
      expect(response).to have_http_status(:forbidden)
      expect(CommunicationTemplate.exists?(standard.id)).to be(true)
    end

    it 'a company admin makes and changes its own copy, which stays its own' do
      post base, params: { template: { name: 'Ours', template_type: 'company_user_invitation', channel: 'email',
                                       subject: 'Hi', body: 'Welcome', is_active: true } },
                 headers: auth(admin), as: :json
      expect(response).to have_http_status(:created)
      own = CommunicationTemplate.find_by(name: 'Ours')
      expect(own.company_id).to eq(company.id)

      patch "#{base}/#{own.id}", params: { template: { body: 'Changed', company_id: '' } }, headers: auth(admin), as: :json
      expect(response).to have_http_status(:ok)
      expect(own.reload).to have_attributes(body: 'Changed', company_id: company.id)

      delete "#{base}/#{own.id}", headers: auth(admin)
      expect(response).to have_http_status(:ok)
    end

    it "another company's id in the header does not reach that company's templates" do
      theirs = template(company_id: other_company.id, name: 'Theirs')
      spoof = { 'X-Company-ID' => other_company.id.to_s }

      get "#{base}/#{theirs.id}", headers: auth(admin, spoof)
      expect(response).to have_http_status(:forbidden)

      patch "#{base}/#{theirs.id}", params: { template: { body: 'Changed' } }, headers: auth(admin, spoof), as: :json
      expect(response).to have_http_status(:forbidden)
      expect(theirs.reload.body).to eq('Join us')

      delete "#{base}/#{theirs.id}", headers: auth(admin, spoof)
      expect(response).to have_http_status(:forbidden)

      post base, params: { template: { name: 'Planted', template_type: 'company_user_invitation', channel: 'email',
                                       subject: 'Hi', body: 'x', company_id: other_company.id } },
                 headers: auth(admin, spoof), as: :json
      expect(CommunicationTemplate.find_by(name: 'Planted').company_id).to eq(company.id)
    end

    it 'the platform team can still change it' do
      patch "#{base}/#{standard.id}", params: { template: { body: 'Better' } }, headers: auth(platform), as: :json
      expect(response).to have_http_status(:ok)
      expect(standard.reload.body).to eq('Better')
    end
  end
end
