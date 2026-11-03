# frozen_string_literal: true

require 'rails_helper'

# Adding a list of people to a company, some of whom already sign in elsewhere,
# without researching who is who first (the install company for a dealer).
RSpec.describe 'Bulk invite and linked first logins', type: :request do
  let(:dealer) { create(:company, name: 'Easy Homes') }
  let(:install) { create(:company, name: 'Easy Install', industry: 'installer') }

  let(:platform_admin) do
    User.create!(email: 'ops@platform.example', first_name: 'Ops', last_name: 'Team', password: 'Pass1234!',
                 company_id: dealer.id, role: 'platform_admin', status: 'active')
  end
  let(:install_admin) do
    User.create!(email: 'boss@install.example', first_name: 'Boss', last_name: 'Install', password: 'Pass1234!',
                 company_id: install.id, role: 'company_admin', status: 'active')
  end

  def body = JSON.parse(response.body)

  def headers_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}", 'Content-Type' => 'application/json' }
  end

  def dealer_user(email, role_record, signed_in: true)
    user = User.create!(email: email, first_name: email.split('@').first.capitalize, last_name: 'Dealer', password: 'Pass1234!',
                        company_id: dealer.id, role: role_record.name, status: 'active',
                        last_sign_in_at: signed_in ? 1.day.ago : nil)
    UserRoleAssignment.create!(user: user, role: role_record, company_id: dealer.id, tier: 'company', assigned_at: Time.current)
    user
  end

  def bulk_invite(as:, people:, role: 'company_staff', match: false)
    post "/api/companies/#{install.id}/users/bulk-invite",
         params: { people: people, role: role, match_existing_roles: match }.to_json, headers: headers_for(as)
  end

  def accept(invitation_token, params)
    post "/api/public/invitations/accept?token=#{invitation_token}", params: params.to_json,
                                                                     headers: { 'Content-Type' => 'application/json' }
  end

  # Sends nothing, and keeps the raw token the way only the message would have it.
  def capture_tokens
    tokens = {}
    allow_any_instance_of(InvitationService).to receive(:send_invitation) do |_service, invitation, raw_token|
      tokens[invitation.email] = raw_token
    end
    tokens
  end

  let!(:admin_role) { Role.find_or_create_by!(company_id: nil, tier: 'company', key: 'company_admin') { |r| r.name = 'Company Administrator'; r.is_system_role = true } }
  let!(:staff_role) { Role.find_or_create_by!(company_id: nil, tier: 'company', key: 'company_staff') { |r| r.name = 'Company Staff'; r.is_system_role = true } }
  let!(:rep_role) { Role.find_or_create_by!(company_id: nil, tier: 'location', key: 'sales_rep') { |r| r.name = 'Sales Representative'; r.is_system_role = true } }
  let!(:custom_role) do
    role = Role.create!(company_id: dealer.id, tier: 'company', key: 'admin_copy_abc123', name: 'Company Administrator (Copy)')
    RolePermission.create!(role: role, resource: Resource.create!(key: 'bulk_invite_spec', name: 'Spec'),
                           action: Action.create!(key: 'bulk_invite_read', name: 'Read'),
                           scope: Scope.create!(key: 'bulk_invite_all', name: 'All'), granted: true)
    role
  end

  describe 'POST bulk-invite' do
    before { capture_tokens }

    it 'sorts out new people, people with a login, people already here and bad emails' do
      rep = dealer_user('rep@easy.example', rep_role)
      install_admin

      bulk_invite(as: platform_admin, people: [
        { email: 'New@easy.example', name: 'New Person' },
        { email: rep.email.upcase, name: 'Rep Dealer' },
        { email: 'rep@easy.example', name: 'Duplicate Line' },
        { email: install_admin.email, name: 'Boss' },
        { email: 'not an email', name: 'Oops' }
      ])

      expect(response).to have_http_status(:ok)
      by_email = body['results'].index_by { |r| r['email'] }
      expect(by_email.keys).to contain_exactly('new@easy.example', 'rep@easy.example', 'boss@install.example', 'not an email')
      expect(by_email['new@easy.example']).to include('status' => 'invited', 'existing_login' => false)
      expect(by_email['rep@easy.example']).to include('status' => 'invited', 'existing_login' => true)
      expect(by_email['boss@install.example']['status']).to eq('already_here')
      expect(by_email['not an email']['status']).to eq('failed')
      expect(body['invited']).to eq(2)

      expect(install.users.find_by(email: 'rep@easy.example').primary_user).to eq(rep)
      expect(rep.reload.company_id).to eq(dealer.id)
    end

    it 'gives each person the role they already have, copying a custom role into the company' do
      dealer_user('owner@easy.example', admin_role)
      dealer_user('rep@easy.example', rep_role)
      dealer_user('copy@easy.example', custom_role)

      bulk_invite(as: platform_admin, match: true, role: 'company_staff', people: [
        { email: 'owner@easy.example' }, { email: 'rep@easy.example' }, { email: 'copy@easy.example' },
        { email: 'brand.new@easy.example', name: 'Brand New' }
      ])

      expect(body['results'].map { |r| r['role'] }).to eq(['Company Administrator', 'Sales Representative', 'Company Administrator (Copy)', 'company_staff'])

      copy = Role.find_by!(company_id: install.id, name: 'Company Administrator (Copy)')
      expect(copy.id).not_to eq(custom_role.id)
      expect(copy.role_permissions.pluck(:resource_id)).to eq(custom_role.role_permissions.pluck(:resource_id))

      assigned = ->(email) { install.users.find_by(email: email).user_role_assignments.where(company_id: install.id).map(&:role) }
      expect(assigned.call('copy@easy.example')).to eq([copy])
      expect(assigned.call('rep@easy.example')).to eq([rep_role])
      expect(assigned.call('owner@easy.example')).to eq([admin_role])
    end

    it 'reuses the copied role for the next person instead of making another' do
      dealer_user('one@easy.example', custom_role)
      dealer_user('two@easy.example', custom_role)

      bulk_invite(as: platform_admin, match: true, people: [{ email: 'one@easy.example' }, { email: 'two@easy.example' }])

      expect(Role.where(company_id: install.id, name: 'Company Administrator (Copy)').count).to eq(1)
    end

    it 'only keeps roles on an installer company' do
      dealer_user('rep@easy.example', rep_role)
      install.update!(industry: 'manufactured_housing')

      bulk_invite(as: platform_admin, match: true, people: [{ email: 'rep@easy.example' }])

      expect(response).to have_http_status(:forbidden)
      expect(install.users.where(email: 'rep@easy.example')).to be_empty
    end

    it "won't let a company admin match roles or see who already has a login" do
      dealer_user('rep@easy.example', rep_role)

      bulk_invite(as: install_admin, match: true, people: [{ email: 'rep@easy.example' }])
      expect(response).to have_http_status(:forbidden)

      bulk_invite(as: install_admin, people: [{ email: 'rep@easy.example' }, { email: 'new@easy.example' }])
      expect(response).to have_http_status(:ok)
      expect(body['results']).to all(satisfy { |r| !r.key?('existing_login') })
    end

    it 'never gives a platform admin a linked account' do
      bulk_invite(as: platform_admin, people: [{ email: platform_admin.email }])

      expect(install.users.where(email: platform_admin.email)).to be_empty
      expect(body['results'].first['status']).to eq('failed')
    end

    it 'caps the list' do
      bulk_invite(as: platform_admin, people: Array.new(51) { |n| { email: "p#{n}@easy.example" } })

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'a role name another company also uses' do
    it "assigns this company's role, never the other company's" do
      mine = Role.create!(company_id: install.id, tier: 'company', key: 'mine_copy', name: custom_role.name)
      user = User.create!(email: 'x@install.example', first_name: 'X', last_name: 'Y', password: 'Pass1234!',
                          company_id: install.id, role: custom_role.name, status: 'active')

      user.assign_rbac_role(custom_role.name, company_id: install.id)

      expect(user.user_role_assignments.map(&:role)).to eq([mine])
    end

    it "refuses another company's custom role outright" do
      user = User.create!(email: 'x@install.example', first_name: 'X', last_name: 'Y', password: 'Pass1234!',
                          company_id: install.id, role: 'staff', status: 'active')

      expect(user.assign_rbac_role(custom_role.key, company_id: install.id)).to be_nil
    end
  end

  describe 'GET available-roles' do
    it "offers system roles and this company's own, never another company's" do
      mine = Role.create!(company_id: install.id, tier: 'company', key: 'install_lead', name: 'Install Lead')

      get "/api/companies/#{install.id}/users/available-roles", headers: headers_for(platform_admin)

      keys = body['roles'].map { |r| r['key'] }
      expect(keys).to include(mine.key, staff_role.key)
      expect(keys).not_to include(custom_role.key)
    end
  end

  describe 'someone who has never signed in' do
    let!(:rep) { dealer_user('rep@easy.example', rep_role, signed_in: false) }

    it 'creates their first password from an emailed invite, and can then reach both companies' do
      tokens = capture_tokens
      bulk_invite(as: platform_admin, match: true, people: [{ email: rep.email }])
      token = tokens[rep.email]

      get '/api/public/invitations/verify', params: { token: token }
      expect(body).to include('existingAccount' => true, 'setsPassword' => true)

      accept(token, password: 'short')
      expect(body['success']).to be(false)

      accept(token, password: 'BrandNew123!')
      expect(body['success']).to be(true)
      expect(body['token']).to be_present
      expect(body['user']['company_id']).to eq(install.id)
      expect(rep.reload.never_signed_in?).to be(false)
      expect(rep.reload.authenticate('BrandNew123!')).to be_truthy
      expect(rep.company_accounts.map(&:company_id)).to eq([dealer.id, install.id])
    end

    it "can't be taken over with an invite texted to the inviter's phone" do
      tokens = capture_tokens
      InvitationService.new(invited_by: install_admin, company: install).create_invitation(
        invitation_type: 'company_user', email: rep.email, phone: '+13035550100', delivery_method: 'sms', role: 'company_staff'
      )
      token = tokens[rep.email]
      digest = rep.reload.password_digest

      get '/api/public/invitations/verify', params: { token: token }
      expect(body['setsPassword']).to be(false)

      accept(token, password: 'Attacker123!')
      expect(body['success']).to be(false)
      expect(rep.reload.password_digest).to eq(digest)
      expect(rep.company_accounts.map(&:company_id)).to eq([dealer.id])
    end

    it 'still asks for the current password once they have signed in' do
      rep.update!(last_sign_in_at: Time.current)
      tokens = capture_tokens
      bulk_invite(as: platform_admin, people: [{ email: rep.email }])
      token = tokens[rep.email]
      digest = rep.reload.password_digest

      get '/api/public/invitations/verify', params: { token: token }
      expect(body['setsPassword']).to be(false)

      accept(token, password: 'NotTheirs123!')
      expect(body['success']).to be(false)
      expect(rep.reload.password_digest).to eq(digest)

      accept(token, password: 'Pass1234!')
      expect(body['success']).to be(true)
      expect(rep.reload.password_digest).to eq(digest)
    end

    it 'sends someone with MFA on to sign in, with no session from the link' do
      rep.update!(mfa_enabled: true)
      tokens = capture_tokens
      bulk_invite(as: platform_admin, people: [{ email: rep.email }])

      accept(tokens[rep.email], password: 'Pass1234!')

      expect(body['success']).to be(true)
      expect(body['existingAccount']).to be(true)
      expect(body['token']).to be_nil
      expect(response.cookies['refresh_token']).to be_nil
    end

    it 'does not offer a new password to a login with MFA on' do
      rep.update!(mfa_enabled: true)
      tokens = capture_tokens
      bulk_invite(as: platform_admin, people: [{ email: rep.email }])

      get '/api/public/invitations/verify', params: { token: tokens[rep.email] }
      expect(body['setsPassword']).to be(false)
    end
  end

  describe 'Add Tenant with an owner who already has a login' do
    def create_tenant(owner_email)
      post '/api/platform/tenants', headers: headers_for(platform_admin), params: {
        tenant: { name: 'New Install Co', subdomain: "install#{SecureRandom.hex(3)}", owner_email: owner_email, send_invitation: true }
      }.to_json
    end

    it 'invites them as the owner and links them as its admin on accept' do
      owner = dealer_user('owner@easy.example', admin_role)
      tokens = capture_tokens

      create_tenant(owner.email)
      expect(response).to have_http_status(:created)
      expect(body).not_to have_key('owner_invitation_error')

      tenant = ::Company.find(body['tenant']['id'])
      expect(tenant.invitations.find_by!(invitation_type: 'tenant').existing_account?).to be(true)

      accept(tokens[owner.email], password: 'Pass1234!')
      expect(body['success']).to be(true)
      expect(body['user']['company_id']).to eq(tenant.id)

      linked = tenant.users.find_by!(email: owner.email)
      expect(linked.primary_user).to eq(owner)
      expect(linked.user_role_assignments.map(&:role)).to eq([admin_role])
      expect(owner.reload.company_id).to eq(dealer.id)
    end

    it 'says so when the owner invite could not be made' do
      capture_tokens
      create_tenant(platform_admin.email)

      expect(response).to have_http_status(:created)
      expect(body['owner_invitation_error']).to include('platform admin')
    end
  end
end
